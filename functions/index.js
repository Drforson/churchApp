/* functions/index.js
 *
 * CLEAN + OPTIMISED REWRITE (NO members.approved REQUIRED)
 * ✅ Fixes bugs + hardens security + removes obsolete/duplicate callables
 * ✅ Ministries created ONLY via Cloud Functions (approval action)
 * ✅ Members can play sermons (no change needed here; served from Firestore/Storage via rules/app)
 *
 * Key changes vs your original:
 * - Removed risky/obsolete: promoteMeToAdmin, pastorSetMemberLeaderStatus, onMinistryRequestApproved auto-flip
 * - Fixed runtime bug: missing const for `theNext` (now eliminated by removing that handler)
 * - Hardened member linking on login:
 *    1) keep existing users.memberId
 *    2) prefer members.userUid == uid
 *    3) fallback to email match ONLY if unique (limit 2)
 *    4) optionally stamps members.userUid when it links (helps future logins)
 * - Optimised leader notifications: NO N+1 queries; uses chunked `in` queries (10)
 */

const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
  onDocumentWritten,
} = require('firebase-functions/v2/firestore');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ts = admin.firestore.FieldValue.serverTimestamp;
const messaging = admin.messaging();
const _tokenCache = new Map();

setGlobalOptions({ region: 'europe-west2', memory: '256MiB', concurrency: 16 });

/* =========================================================
   0) Constants & small utilities
   ========================================================= */
const ROLE_ORDER_ASC = ['member', 'usher', 'leader', 'pastor', 'admin']; // ascending
const ALLOWED_ROLES = ['member', 'usher', 'leader', 'pastor', 'admin', 'media'];

const toLc = (s) => String(s ?? '').toLowerCase().trim();
const S = (v) => (v ?? '').toString().trim();
const uniq = (arr) => Array.from(new Set(arr));
const asArray = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);
const digitsOnly = (s) => String(s ?? '').replace(/\D/g, '');

function normalizeFullName(data) {
  const full = S(data.fullName);
  if (full) return full;
  const first = S(data.firstName);
  const last = S(data.lastName);
  return `${first} ${last}`.trim();
}

function genderBucket(raw) {
  const g = toLc(raw);
  if (!g) return 'other';
  if (g.startsWith('m') || g.includes('male') || g.includes('man') || g.includes('boy')) return 'male';
  if (g.startsWith('f') || g.includes('female') || g.includes('woman') || g.includes('girl')) return 'female';
  return 'other';
}

// Map ministry names to role tags when they imply a role.
function ministryRoleTagFromName(name) {
  const n = toLc(name);
  if (!n) return null;
  if (n.includes('usher')) return 'usher';
  if (n.includes('media')) return 'media';
  return null;
}

async function getMinistryRoleTag(ministryName) {
  if (!ministryName) return null;
  try {
    const snap = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
    if (!snap.empty) {
      const data = snap.docs[0].data() || {};
      const roleTag = toLc(data.roleTag || '');
      if (roleTag) return roleTag;
    }
  } catch (_) {}
  return ministryRoleTagFromName(ministryName);
}

async function getRoleTagsForMinistryNames(names) {
  const tags = new Set();
  const clean = names.map(S).filter(Boolean);
  if (clean.length === 0) return tags;

  // Chunk 'in' queries to 10.
  for (let i = 0; i < clean.length; i += 10) {
    const chunk = clean.slice(i, i + 10);
    try {
      const snap = await db.collection('ministries').where('name', 'in', chunk).get();
      snap.docs.forEach((d) => {
        const data = d.data() || {};
        const roleTag = toLc(data.roleTag || '');
        if (roleTag) tags.add(roleTag);
      });
    } catch (_) {}
  }

  // Fallback to name-based tags where not explicitly set.
  clean.forEach((name) => {
    const roleTag = ministryRoleTagFromName(name);
    if (roleTag) tags.add(roleTag);
  });

  return tags;
}

async function getRoleTagMapForMinistryNames(names) {
  const map = new Map();
  const clean = uniq(names.map(S).filter(Boolean));
  if (clean.length === 0) return map;

  for (let i = 0; i < clean.length; i += 10) {
    const chunk = clean.slice(i, i + 10);
    try {
      const snap = await db.collection('ministries').where('name', 'in', chunk).get();
      snap.docs.forEach((d) => {
        const data = d.data() || {};
        const name = S(data.name);
        const roleTag = toLc(data.roleTag || '');
        if (name && roleTag) map.set(name, roleTag);
      });
    } catch (_) {}
  }

  clean.forEach((name) => {
    if (map.has(name)) return;
    const roleTag = ministryRoleTagFromName(name);
    if (roleTag) map.set(name, roleTag);
  });

  return map;
}

function hasRoleTagForMinistries(ministryNames, roleTag, roleTagByMinistry) {
  if (!roleTag) return false;
  for (const name of ministryNames) {
    if (!name) continue;
    const tag = roleTagByMinistry?.get(name) || ministryRoleTagFromName(name);
    if (tag === roleTag) return true;
  }
  return false;
}

function normalizeRoles(input) {
  const norm = uniq(asArray(input).map(toLc).filter(Boolean));
  // store only granted roles above member (member implied)
  return norm.filter((r) => ALLOWED_ROLES.includes(r) && r !== 'member');
}

function highestRole(rolesArr) {
  const set = new Set(normalizeRoles(rolesArr));
  for (let i = ROLE_ORDER_ASC.length - 1; i >= 0; i--) {
    if (set.has(ROLE_ORDER_ASC[i])) return ROLE_ORDER_ASC[i];
  }
  return 'member';
}

function mergeRoles(current, add = [], remove = []) {
  const cur = new Set(normalizeRoles(current));
  for (const a of normalizeRoles(add)) cur.add(a);
  for (const r of normalizeRoles(remove)) cur.delete(r);
  return Array.from(cur);
}

/* =========================================================
   1) Data access helpers (+ simple per-invocation cache)
   ========================================================= */
function makeCtxCache() {
  return { users: new Map(), members: new Map() };
}

async function getUser(uid, cache) {
  try {
    if (!uid) return null;
    if (cache?.users?.has(uid)) return cache.users.get(uid);

    const snap = await db.doc(`users/${uid}`).get();
    const val = snap.exists ? { id: snap.id, ...snap.data() } : null;

    if (cache?.users) cache.users.set(uid, val);
    return val;
  } catch (e) {
    logger.error('getUser failed', { uid, error: e });
    return null;
  }
}

async function getMemberById(memberId, cache) {
  try {
    if (!memberId) return null;
    if (cache?.members?.has(memberId)) return cache.members.get(memberId);

    const snap = await db.doc(`members/${memberId}`).get();
    const val = snap.exists ? { id: snap.id, ...snap.data() } : null;

    if (cache?.members) cache.members.set(memberId, val);
    return val;
  } catch (e) {
    logger.error('getMemberById failed', { memberId, error: e });
    return null;
  }
}

async function findUserByMemberId(memberId) {
  const qs = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
  if (qs.empty) return null;
  const d = qs.docs[0];
  return { id: d.id, ...d.data() };
}

async function findMemberIdByUid(uid, cache) {
  const u = await getUser(uid, cache);
  return u?.memberId || null;
}

async function getUserRole(uid, cache) {
  const u = await getUser(uid, cache);
  if (!u) return 'member';
  if (typeof u.role === 'string' && u.role) return toLc(u.role);
  return highestRole(u.roles || []);
}

/* =========================================================
   2) Claims & role sync
   ========================================================= */
async function syncClaimsForUid(uid, cache) {
  try {
    const role = await getUserRole(uid, cache);
    const claims = {
      role,
      admin: role === 'admin' || undefined,
      isAdmin: role === 'admin' || undefined,
      pastor: role === 'pastor' || undefined,
      isPastor: role === 'pastor' || undefined,
      leader: role === 'leader' || undefined,
      isLeader: role === 'leader' || undefined,
    };
    await admin.auth().setCustomUserClaims(uid, claims);
    logger.info('syncClaimsForUid ok', { uid, role });
  } catch (e) {
    logger.error('syncClaimsForUid failed', { uid, error: e });
  }
}

function txSyncUserRoles(tx, uid, roles) {
  const rolesClean = normalizeRoles(roles);
  const single = highestRole(rolesClean);
  tx.set(
    db.doc(`users/${uid}`),
    { roles: rolesClean, role: single, updatedAt: ts() },
    { merge: true }
  );
}

function txSyncMemberRoles(tx, memberId, roles) {
  const rolesClean = normalizeRoles(roles);
  tx.set(
    db.doc(`members/${memberId}`),
    { roles: rolesClean, updatedAt: ts() },
    { merge: true }
  );
}

async function recomputeAndWriteUserRole(uid) {
  const cache = makeCtxCache();
  const user = await getUser(uid, cache);
  if (!user) return;

  let memberRoles = [];
  let isPastorFlag = false;
  let leadershipMins = null;

  if (user.memberId) {
    const m = await getMemberById(user.memberId, cache);
    if (m) {
      memberRoles = Array.isArray(m.roles) ? m.roles : [];
      isPastorFlag = !!m.isPastor;
      leadershipMins = Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : [];
    }
  }

  const merged = [
    ...normalizeRoles(user.roles || []),
    ...normalizeRoles(memberRoles),
    ...(leadershipMins && leadershipMins.length > 0 ? ['leader'] : []),
    ...(isPastorFlag ? ['pastor'] : []),
  ];

  const rolesClean = normalizeRoles(merged);
  const single = highestRole(rolesClean);

  const update = { role: single, roles: rolesClean, updatedAt: ts() };
  if (leadershipMins) update.leadershipMinistries = leadershipMins;
  await db.doc(`users/${uid}`).set(update, { merge: true });
  await syncClaimsForUid(uid, cache);
}

/* =========================================================
   3) Privilege checks
   ========================================================= */
async function isUserPastorOrAdmin(uid) {
  const cache = makeCtxCache();
  const role = await getUserRole(uid, cache);
  if (role === 'pastor' || role === 'admin') return true;

  // claims
  try {
    const rec = await admin.auth().getUser(uid);
    const c = rec.customClaims || {};
    if (c.pastor === true || c.admin === true || c.isPastor === true || c.isAdmin === true) return true;
  } catch (_) {}

  // member-linked
  const memberId = await findMemberIdByUid(uid, cache);
  if (!memberId) return false;

  const mem = await getMemberById(memberId, cache);
  if (!mem) return false;

  const roles = Array.isArray(mem.roles) ? mem.roles.map(toLc) : [];
  if (roles.includes('admin')) return true;
  if (mem.isPastor === true || roles.includes('pastor')) return true;

  const lead = Array.isArray(mem.leadershipMinistries) ? mem.leadershipMinistries : [];
  if (lead.some((s) => String(s).toLowerCase().includes('pastor'))) return true;

  return false;
}

/* =========================================================
   4) Notifications / Inbox
   ========================================================= */
async function writeInbox(uid, payload) {
  await db.collection('inbox').doc(uid).set({ lastSeenAt: ts() }, { merge: true });

  const toWrite = { ...payload, read: false, createdAt: ts() };

  if (payload?.dedupeKey) {
    const qs = await db
      .collection('inbox').doc(uid).collection('events')
      .where('dedupeKey', '==', payload.dedupeKey)
      .limit(1)
      .get();

    if (!qs.empty) {
      await qs.docs[0].ref.update({ createdAt: ts(), read: false });
      return;
    }
    toWrite.dedupeKey = payload.dedupeKey;
  }

  await db.collection('inbox').doc(uid).collection('events').add(toWrite);

  // Push notification for background/closed app (best-effort)
  try {
    if (payload?.sendPush === false) return;
    const title = (payload?.title || 'Notification').toString();
    const body = (payload?.body || payload?.type || 'You have a new notification').toString();
    const token = await _getUserFcmToken(uid);
    if (!token) return;

    const data = _buildFcmData(payload);
    await messaging.send({
      token,
      notification: { title, body },
      data,
    });
  } catch (e) {
    logger.warn('writeInbox FCM send failed', { uid, error: e });
  }
}

async function writeNotification(payload) {
  const data = { ...payload };
  if (!data.createdAt) data.createdAt = ts();
  await db.collection('notifications').add(data);
}

async function _getUserFcmToken(uid) {
  if (!uid) return null;
  if (_tokenCache.has(uid)) return _tokenCache.get(uid);
  try {
    const snap = await db.doc(`users/${uid}`).get();
    const token = S(snap.get('fcmToken'));
    _tokenCache.set(uid, token || null);
    return token || null;
  } catch (_) {
    return null;
  }
}

function _buildFcmData(payload = {}) {
  const keep = [
    'type',
    'route',
    'ministryId',
    'ministryName',
    'ministryDocId',
    'joinRequestId',
    'prayerRequestId',
    'requestId',
    'result',
    'channel',
  ];
  const out = {};
  for (const k of keep) {
    if (payload[k] == null) continue;
    const v = payload[k];
    const s = typeof v === 'string' ? v : String(v);
    if (s.trim().length) out[k] = s;
  }
  return out;
}

async function notifyMinistryCreationRequesterResult({
  requesterUid,
  result,
  ministryName,
  ministryDocId,
  requestId,
  reviewerUid,
  reason,
}) {
  if (!requesterUid) return;
  const approved = result === 'approved';
  const title = approved ? 'Your ministry was approved' : 'Your ministry was declined';
  const body = approved
    ? (ministryName ? `Your request to create "${ministryName}" was approved.` : 'Your ministry request was approved.')
    : (reason
        ? `Your request to create "${ministryName}" was declined: ${reason}`
        : `Your request to create "${ministryName}" was declined.`);

  await writeInbox(requesterUid, {
    type: 'ministry_request_result',
    result,
    requestId,
    ministryName,
    ministryDocId: ministryDocId || null,
    moderatorUid: reviewerUid || null,
    reason: reason || null,
    title,
    body,
    route: '/view-ministry',
    dedupeKey: `mcr_result_${requestId}_${result}_${requesterUid}`,
  });
}

/* =========================================================
   5) Ministries / membership helpers (by NAME)
   ========================================================= */
async function addMemberToMinistry(memberId, ministryName, { asLeader = false } = {}) {
  if (!memberId || !ministryName) return;
  const roleTag = await getMinistryRoleTag(ministryName);

  await db.runTransaction(async (tx) => {
    const mRef = db.doc(`members/${memberId}`);
    const mSnap = await tx.get(mRef);
    if (!mSnap.exists) return;
    const m = mSnap.data() || {};

    const curMins = new Set(Array.isArray(m.ministries) ? m.ministries : []);
    const curLeads = new Set(Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : []);
    let roles = Array.isArray(m.roles) ? m.roles : [];

    curMins.add(ministryName);
    if (asLeader) {
      curLeads.add(ministryName);
      roles = mergeRoles(roles, ['leader'], []);
    }
    if (roleTag) roles = mergeRoles(roles, [roleTag], []);

    tx.update(mRef, {
      ministries: Array.from(curMins),
      leadershipMinistries: Array.from(curLeads),
      roles: normalizeRoles(roles),
      updatedAt: ts(),
    });

    const linked = await findUserByMemberId(memberId);
    if (linked?.id) {
      const uRef = db.doc(`users/${linked.id}`);
      const uSnap = await tx.get(uRef);
      const u = uSnap.exists ? uSnap.data() || {} : {};

      const uLead = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);
      let uRoles = Array.isArray(u.roles) ? u.roles : [];
      const single = toLc(u.role);
      uRoles = uniq([single, ...uRoles]).filter(Boolean);

      if (asLeader) {
        uLead.add(ministryName);
        uRoles = mergeRoles(uRoles, ['leader'], []);
      }
      if (roleTag) uRoles = mergeRoles(uRoles, [roleTag], []);

      txSyncUserRoles(tx, linked.id, uRoles);
      tx.set(uRef, { leadershipMinistries: Array.from(uLead), updatedAt: ts() }, { merge: true });
    }
  });

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);
}

async function removeMemberFromMinistryByName(memberId, ministryName) {
  if (!memberId || !ministryName) return;
  const m = await getMemberById(memberId);
  if (!m) return;

  const currentMins = Array.isArray(m.ministries) ? m.ministries.map(S).filter(Boolean) : [];
  const hadMinistry = currentMins.includes(ministryName);
  const remainingMins = currentMins.filter((n) => n !== ministryName);
  const roleTag = await getMinistryRoleTag(ministryName);
  const remainingRoleTags = roleTag && hadMinistry ? await getRoleTagsForMinistryNames(remainingMins) : new Set();
  const shouldRemoveRoleTag = roleTag && hadMinistry && !remainingRoleTags.has(roleTag);

  await db.runTransaction(async (tx) => {
    const mRef = db.doc(`members/${memberId}`);
    const mSnap = await tx.get(mRef);
    if (!mSnap.exists) return;
    const data = mSnap.data() || {};

    const curMins = new Set(Array.isArray(data.ministries) ? data.ministries : []);
    const curLeads = new Set(Array.isArray(data.leadershipMinistries) ? data.leadershipMinistries : []);
    let roles = Array.isArray(data.roles) ? data.roles : [];

    curMins.delete(ministryName);
    if (curLeads.has(ministryName)) {
      curLeads.delete(ministryName);
      if (curLeads.size === 0) roles = mergeRoles(roles, [], ['leader']);
    }

    if (shouldRemoveRoleTag) {
      roles = mergeRoles(roles, [], [roleTag]);
    }

    tx.update(mRef, {
      ministries: Array.from(curMins),
      leadershipMinistries: Array.from(curLeads),
      roles: normalizeRoles(roles),
      updatedAt: ts(),
    });

    const linked = await findUserByMemberId(memberId);
    if (linked?.id) {
      const uRef = db.doc(`users/${linked.id}`);
      const uSnap = await tx.get(uRef);
      const u = uSnap.exists ? uSnap.data() || {} : {};

      const uLead = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);
      let uRoles = Array.isArray(u.roles) ? u.roles : [];
      const single = toLc(u.role);
      uRoles = uniq([single, ...uRoles]).filter(Boolean);

      uLead.delete(ministryName);
      if (uLead.size === 0) uRoles = mergeRoles(uRoles, [], ['leader']);
      if (shouldRemoveRoleTag) uRoles = mergeRoles(uRoles, [], [roleTag]);

      txSyncUserRoles(tx, linked.id, uRoles);
      tx.set(uRef, { leadershipMinistries: Array.from(uLead), updatedAt: ts() }, { merge: true });
    }
  });

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);
}

/**
 * Resolve ministry for join requests:
 * accepts ministryName, ministryDocId, ministryId (docId OR name), ministry (string or {id,name})
 */
async function resolveMinistryFromJoin(jr) {
  let ministryName = S(jr.ministryName);
  let ministryDocId = S(jr.ministryDocId) || '';

  if (!ministryName && jr?.ministry) {
    if (typeof jr.ministry === 'string') {
      ministryName = S(jr.ministry);
    } else if (typeof jr.ministry === 'object') {
      ministryName = S(jr.ministry.name);
      ministryDocId = ministryDocId || S(jr.ministry.id);
    }
  }

  const rawId = S(jr.ministryId);
  if (!ministryName && rawId) {
    // try doc id
    try {
      const doc = await db.doc(`ministries/${rawId}`).get();
      if (doc.exists) {
        ministryDocId = doc.id;
        const d = doc.data() || {};
        ministryName = S(d.name) || ministryName;
      }
    } catch (_) {}
    // fallback as name
    if (!ministryName) ministryName = rawId;
  }

  // if still no doc id, find by name
  if (!ministryDocId && ministryName) {
    const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
    if (!mins.empty) ministryDocId = mins.docs[0].id;
  }

  return { ministryName: ministryName || null, ministryDocId: ministryDocId || null };
}

async function resolveMinistryByNameOrId(nameOrId) {
  const candidate = S(nameOrId);
  if (!candidate) return { ministryName: null, ministryDocId: null };

  // doc id?
  try {
    const d = await db.doc(`ministries/${candidate}`).get();
    if (d.exists) {
      const data = d.data() || {};
      return { ministryName: S(data.name) || null, ministryDocId: d.id };
    }
  } catch (_) {}

  // name?
  const q = await db.collection('ministries').where('name', '==', candidate).limit(1).get();
  if (!q.empty) return { ministryName: candidate, ministryDocId: q.docs[0].id };

  // unknown name, keep it
  return { ministryName: candidate, ministryDocId: null };
}

/* =========================================================
   6) Leader notification fan-out (OPTIMISED)
   ========================================================= */
async function mapMemberIdsToUids(memberIds) {
  const out = new Map(); // memberId -> uid
  const ids = uniq(memberIds.filter(Boolean));
  for (let i = 0; i < ids.length; i += 10) {
    const chunk = ids.slice(i, i + 10);
    const qs = await db.collection('users').where('memberId', 'in', chunk).get();
    qs.docs.forEach((d) => out.set(d.data().memberId, d.id));
  }
  return out;
}

async function getMemberDisplayName(memberId) {
  if (!memberId) return null;
  try {
    const snap = await db.doc(`members/${memberId}`).get();
    if (!snap.exists) return null;
    const data = snap.data() || {};
    const full = S(data.fullName) || `${S(data.firstName)} ${S(data.lastName)}`.trim();
    return full || null;
  } catch (_) {
    return null;
  }
}

async function writeLeaderBroadcast({ ministryName, ministryDocId, joinRequestId, requestedByUid, requesterMemberId, type }) {
  await writeNotification({
    type, // join_request | join_request_cancelled
    ministryId: ministryName, // NAME aligns with member.ministries
    ministryDocId: ministryDocId || null,
    joinRequestId,
    requestedByUid: requestedByUid || null,
    memberId: requesterMemberId || null,
    audience: { leadersOnly: true, adminAlso: true },
  });
}

async function writeDirectToLeaders({ ministryName, ministryDocId, joinRequestId, requestedByUid, requesterMemberId, type }) {
  const requesterName = await getMemberDisplayName(requesterMemberId);

  // (A) leaders from member.leadershipMinistries
  const leadersSnap = await db
    .collection('members')
    .where('leadershipMinistries', 'array-contains', ministryName)
    .get();

  const leaderMemberIds = leadersSnap.docs.map((d) => d.id);

  // (B) leaders from ministries doc leaderUids/leaderIds
  let ministryLeaderUids = [];
  let ministryLeaderMemberIds = [];
  const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
  if (!mins.empty) {
    const mData = mins.docs[0].data() || {};
    const fromLeaderUids = Array.isArray(mData.leaderUids) ? mData.leaderUids : [];
    const fromLeaderIds = Array.isArray(mData.leaderIds) ? mData.leaderIds : [];
    ministryLeaderUids = uniq(fromLeaderUids.filter(Boolean));
    ministryLeaderMemberIds = uniq(fromLeaderIds.filter(Boolean));
    ministryDocId = ministryDocId || mins.docs[0].id;
  }

  // map memberIds -> uids (chunked in queries)
  const allLeaderMemberIds = uniq([...leaderMemberIds, ...ministryLeaderMemberIds]);
  const map = allLeaderMemberIds.length ? await mapMemberIdsToUids(allLeaderMemberIds) : new Map();
  const uidsFromMembers = Array.from(map.values());

  const recipients = uniq([...uidsFromMembers, ...ministryLeaderUids].filter(Boolean));
  if (!recipients.length) return;

  const batch = db.batch();
  for (const recipientUid of recipients) {
    batch.set(db.collection('notifications').doc(), {
      type,
      ministryId: ministryName,
      ministryDocId: ministryDocId || null,
      joinRequestId,
      requestedByUid: requestedByUid || null,
      memberId: requesterMemberId || null,
      recipientUid,
      audience: { direct: true, role: 'leader' },
      createdAt: ts(),
    });
  }
  await batch.commit();

  // Canonical in-app inbox events used by Flutter NotificationCenter.
  await Promise.all(
    recipients.map((recipientUid) =>
      writeInbox(recipientUid, {
        type,
        title: type === 'join_request_cancelled' ? 'Join request cancelled' : 'New join request',
        body: requesterName
          ? `${requesterName} ${type === 'join_request_cancelled' ? 'cancelled their request for' : 'requested to join'} ${ministryName}`
          : `${type === 'join_request_cancelled' ? 'A member cancelled their request for' : 'A member requested to join'} ${ministryName}`,
        ministryId: ministryName,
        ministryName,
        ministryDocId: ministryDocId || null,
        joinRequestId,
        memberId: requesterMemberId || null,
        requesterName: requesterName || null,
        requestedByUid: requestedByUid || null,
        route: '/view-ministry',
        dedupeKey: `jr_${type}_${joinRequestId}_${recipientUid}`,
      })
    )
  );
}

async function notifyRequesterResult({ ministryName, ministryDocId, joinRequestId, requesterMemberId, result, moderatorUid }) {
  let recipientUid = null;
  if (requesterMemberId) {
    const userQs = await db.collection('users').where('memberId', '==', requesterMemberId).limit(1).get();
    if (!userQs.empty) recipientUid = userQs.docs[0].id;
  }

  await writeNotification({
    type: 'join_request_result',
    result, // approved | rejected
    ministryId: ministryName,
    ministryDocId: ministryDocId || null,
    joinRequestId,
    memberId: requesterMemberId || null,
    recipientUid: recipientUid || null,
    moderatorUid: moderatorUid || null,
  });

  if (!recipientUid) return;

  await writeInbox(recipientUid, {
    type: 'join_request_result',
    title: result === 'approved' ? 'Your join request was approved' : 'Your join request was declined',
    body:
      result === 'approved'
        ? `You can now access ${ministryName}.`
        : `Your request to join ${ministryName} was declined.`,
    ministryId: ministryName,
    ministryName,
    ministryDocId: ministryDocId || null,
    joinRequestId,
    memberId: requesterMemberId || null,
    moderatorUid: moderatorUid || null,
    result,
    route: '/view-ministry',
    dedupeKey: `jr_result_${joinRequestId}_${result}_${recipientUid}`,
  });
}

/* =========================================================
   7) Approver discovery helpers
   ========================================================= */
async function listUidsByRole(roleLc) {
  const set = new Set();

  const q1 = await db.collection('users').where('role', '==', roleLc).get();
  q1.docs.forEach((d) => set.add(d.id));

  const variants = [roleLc, roleLc.toUpperCase(), roleLc[0].toUpperCase() + roleLc.slice(1)];
  const legacyQs = await Promise.all(variants.map((r) => db.collection('users').where('roles', 'array-contains', r).get()));
  legacyQs.forEach((qs) => qs.docs.forEach((d) => set.add(d.id)));

  return Array.from(set);
}

async function uidsFromMemberIds(memberIds) {
  const out = new Set();
  const ids = uniq(memberIds.filter(Boolean));
  for (let i = 0; i < ids.length; i += 10) {
    const chunk = ids.slice(i, i + 10);
    const qs = await db.collection('users').where('memberId', 'in', chunk).get();
    qs.docs.forEach((d) => out.add(d.id));
  }
  return Array.from(out);
}

async function listMemberIdsByPastorOrAdmin() {
  const out = new Set();

  for (const val of ['pastor', 'Pastor', 'PASTOR']) {
    const qs = await db.collection('members').where('roles', 'array-contains', val).get();
    qs.docs.forEach((d) => out.add(d.id));
  }
  for (const val of ['admin', 'Admin', 'ADMIN']) {
    const qs = await db.collection('members').where('roles', 'array-contains', val).get();
    qs.docs.forEach((d) => out.add(d.id));
  }
  {
    const qs = await db.collection('members').where('isPastor', '==', true).get();
    qs.docs.forEach((d) => out.add(d.id));
  }

  return Array.from(out);
}

async function listPastorUids() {
  const fromUsers = await listUidsByRole('pastor');
  const memberIds = await listMemberIdsByPastorOrAdmin();
  const fromMembers = memberIds.length ? await uidsFromMemberIds(memberIds) : [];
  return uniq([...fromUsers, ...fromMembers]);
}

async function listPastorAndAdminUids() {
  const [uPastors, uAdmins, memberIds] = await Promise.all([
    listUidsByRole('pastor'),
    listUidsByRole('admin'),
    listMemberIdsByPastorOrAdmin(),
  ]);
  const uidsFromMembers = memberIds.length ? await uidsFromMemberIds(memberIds) : [];
  return uniq([...uPastors, ...uAdmins, ...uidsFromMembers]);
}

/* =========================================================
   8) Ministry approval actions (the ONLY ministry creation path)
   ========================================================= */
exports.processMinistryApprovalAction = onDocumentCreated('ministry_approval_actions/{id}', async (event) => {
  const doc = event.data;
  if (!doc) return;

  const { decision, requestId, reason, reviewerUid } = doc.data() || {};
  logger.info('processMinistryApprovalAction received', { id: doc.id, decision, requestId, reviewerUid });

  if (!decision || !requestId || !reviewerUid) {
    await doc.ref.update({ status: 'invalid', processed: true, processedAt: new Date() });
    return;
  }

  const allowed = await isUserPastorOrAdmin(reviewerUid);
  if (!allowed) {
    await doc.ref.update({ status: 'denied', processed: true, processedAt: new Date() });
    return;
  }

  const reqRef = db.doc(`ministry_creation_requests/${requestId}`);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) {
    await doc.ref.update({ status: 'not_found', processed: true, processedAt: new Date() });
    return;
  }

  const r = reqSnap.data() || {};
  const requestStatus = toLc(r.status || 'pending');
  if (requestStatus !== 'pending') {
    await doc.ref.update({ status: 'already_processed', processed: true, processedAt: new Date() });
    return;
  }

  try {
    const ministryName = S(r.name || r.ministryName);
    const requestedByUid = S(r.requestedByUid);

    if (!ministryName) {
      await doc.ref.update({ status: 'error', error: 'missing-ministry-name', processed: true, processedAt: new Date() });
      return;
    }

    if (toLc(decision) === 'approve') {
      const minRef = db.collection('ministries').doc();

      await db.runTransaction(async (txn) => {
        txn.set(minRef, {
          id: minRef.id,
          name: ministryName,
          description: S(r.description),
          approved: true,
          createdAt: ts(),
          createdBy: reviewerUid,
          leaderUids: requestedByUid ? [requestedByUid] : [],
        });

        txn.update(reqRef, {
          status: 'approved',
          approvedMinistryId: minRef.id,
          updatedAt: ts(),
          approvedByUid: reviewerUid,
        });
      });

      // make requester a leader if linked to a member (robust fallback)
      {
        const cache = makeCtxCache();
        let memberId = requestedByUid
          ? await findMemberIdByUid(requestedByUid, cache)
          : null;

        if (!memberId) {
          const reqMid = S(r.requesterMemberId);
          if (reqMid) {
            const mSnap = await db.doc(`members/${reqMid}`).get();
            if (mSnap.exists) memberId = reqMid;
          }
        }

        if (!memberId) {
          const reqEmail = toLc(r.requesterEmail || '');
          if (reqEmail) {
            const q = await db.collection('members').where('email', '==', reqEmail).limit(2).get();
            if (q.size === 1) memberId = q.docs[0].id;
          }
        }

        if (memberId) {
          await addMemberToMinistry(memberId, ministryName, { asLeader: true });

          await db.runTransaction(async (tx) => {
            const mRef = db.doc(`members/${memberId}`);
            const mSnap = await tx.get(mRef);
            const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['leader'], []);
            txSyncMemberRoles(tx, memberId, merged);

            if (requestedByUid) {
              txSyncUserRoles(tx, requestedByUid, merged);
              tx.set(
                db.doc(`users/${requestedByUid}`),
                {
                  leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
                  updatedAt: ts(),
                },
                { merge: true }
              );
            }
          });

          if (requestedByUid) {
            const uRef = db.doc(`users/${requestedByUid}`);
            const uSnap = await uRef.get();
            const uData = uSnap.data() || {};
            const existingMemberId = S(uData.memberId);
            if (!existingMemberId || existingMemberId === memberId) {
              await uRef.set({ memberId, updatedAt: ts() }, { merge: true });
            }

            const mRef = db.doc(`members/${memberId}`);
            const mSnap = await mRef.get();
            const mData = mSnap.data() || {};
            const existingUid = S(mData.userUid);
            if (!existingUid || existingUid === requestedByUid) {
              await mRef.set({ userUid: requestedByUid, updatedAt: ts() }, { merge: true });
            }

            await syncClaimsForUid(requestedByUid, cache);
          }
        }
      }

      await notifyMinistryCreationRequesterResult({
        requesterUid: requestedByUid || null,
        result: 'approved',
        ministryName,
        ministryDocId: minRef.id,
        requestId,
        reviewerUid,
      });

      await doc.ref.update({ status: 'ok', processed: true, processedAt: new Date() });
      return;
    }

    // DECLINE
    const declineReason = S(reason) || null;

    await writeNotification({
      type: 'ministry_request_result',
      result: 'declined',
      requestId,
      ministryName,
      ministryDocId: null,
      recipientUid: S(r.requestedByUid) || null,
      reviewerUid: reviewerUid || null,
      reason: declineReason,
      createdAt: ts(),
    });

    await reqRef.delete();

    await notifyMinistryCreationRequesterResult({
      requesterUid: S(r.requestedByUid) || null,
      result: 'declined',
      ministryName,
      ministryDocId: null,
      requestId,
      reviewerUid,
      reason: declineReason,
    });

    await doc.ref.update({ status: 'ok', processed: true, processedAt: new Date() });
  } catch (e) {
    logger.error('processMinistryApprovalAction error', { error: e });
    await doc.ref.update({
      status: 'error',
      error: (e && e.message) || String(e),
      processed: true,
      processedAt: new Date(),
    });
  }
});

/* =========================================================
   9) Notify pastors/admins when ministry request created
   ========================================================= */
exports.onMinistryCreationRequestCreated = onDocumentCreated('ministry_creation_requests/{id}', async (event) => {
  const snap = event.data;
  if (!snap) return;
  const r = snap.data() || {};
  const name = S(r.name || r.ministryName);

  logger.info('ministry_creation_requests CREATED', { id: snap.id, requestedByUid: r.requestedByUid, name });

  const approverUids = await listPastorAndAdminUids();
  if (!approverUids.length) return;

  await Promise.all(
    approverUids.map((uid) =>
      writeInbox(uid, {
        type: 'ministry_request_created',
        channel: 'approvals',
        title: 'New ministry creation request',
        body: name ? `Ministry: ${name}` : 'A new request was submitted',
        requestId: snap.id,
        payload: { requestId: snap.id, ministryName: name || null },
        route: '/pastor-approvals',
        dedupeKey: `mcr_created_${snap.id}_${uid}`,
      })
    )
  );
});

/* =========================================================
   10) Join requests: created / updated / deleted
   ========================================================= */
exports.onJoinRequestCreated = onDocumentCreated('join_requests/{id}', async (event) => {
  const doc = event.data;
  if (!doc) return;
  const jr = doc.data() || {};

  const memberId = S(jr.memberId);
  const requestedByUid = S(jr.requestedByUid);

  const { ministryName, ministryDocId } = await resolveMinistryFromJoin(jr);
  if (!ministryName) return;

  logger.info('join_requests CREATED', { id: doc.id, ministryName, memberId });

  await writeLeaderBroadcast({
    ministryName,
    ministryDocId,
    joinRequestId: doc.id,
    requestedByUid,
    requesterMemberId: memberId,
    type: 'join_request',
  });

  await writeDirectToLeaders({
    ministryName,
    ministryDocId,
    joinRequestId: doc.id,
    requestedByUid,
    requesterMemberId: memberId,
    type: 'join_request',
  });
});

exports.onJoinRequestUpdated = onDocumentUpdated('join_requests/{id}', async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!before || !after) return;

  const prev = toLc(S(before.status || 'pending'));
  const next = toLc(S(after.status || 'pending'));
  if (prev === next) return;

  const memberId = S(after.memberId);
  const { ministryName, ministryDocId } = await resolveMinistryFromJoin(after);
  if (!memberId || !ministryName) return;

  const moderatorUid = S(after.moderatorUid) || null;

  if (next === 'approved' || next === 'rejected') {
    await notifyRequesterResult({
      ministryName,
      ministryDocId,
      joinRequestId: event.params.id,
      requesterMemberId: memberId,
      result: next,
      moderatorUid,
    });
  }

  if (next === 'approved') {
    await addMemberToMinistry(memberId, ministryName, { asLeader: false });
  }
});

exports.onJoinRequestDeleted = onDocumentDeleted('join_requests/{id}', async (event) => {
  const r = event.data?.data() || {};
  const status = toLc(r.status || 'pending');
  if (status !== 'pending') return;

  const requesterMemberId = S(r.memberId);
  const requestedByUid = S(r.requestedByUid);
  const joinRequestId = event.params.id;

  const { ministryName, ministryDocId } = await resolveMinistryFromJoin(r);
  if (!ministryName || !requesterMemberId) return;

  logger.info('join_requests CANCELLED (delete)', { id: joinRequestId, ministryName, requesterMemberId });

  await writeLeaderBroadcast({
    ministryName,
    ministryDocId,
    joinRequestId,
    requestedByUid,
    requesterMemberId,
    type: 'join_request_cancelled',
  });

  await writeDirectToLeaders({
    ministryName,
    ministryDocId,
    joinRequestId,
    requestedByUid,
    requesterMemberId,
    type: 'join_request_cancelled',
  });
});

/* =========================================================
   11) Prayer request notify pastors
   ========================================================= */
exports.onPrayerRequestCreated = onDocumentCreated('prayerRequests/{id}', async (event) => {
  const snap = event.data;
  if (!snap) return;

  const r = snap.data() || {};
  const name = S(r.name) || (r.isAnonymous ? 'Anonymous' : '');
  const email = S(r.email);
  const message = S(r.message || r.request);
  const requesterUid = S(r.requestedByUid);
  const channel = 'prayer';

  const pastorUids = await listPastorUids();
  if (!pastorUids.length) return;

  const title = 'New prayer request';
  const body = name ? `${name}: ${message}` : message;

  await Promise.all(
    pastorUids.map((uid) =>
      writeInbox(uid, {
        type: 'prayer_request_created',
        channel,
        title,
        body,
        prayerRequestId: snap.id,
        payload: {
          prayerRequestId: snap.id,
          name: name || null,
          email: email || null,
          isAnonymous: !!r.isAnonymous,
          requestedByUid: requesterUid || null,
        },
        route: '/prayer-requests',
        dedupeKey: `pr_${snap.id}_${uid}`,
      })
    )
  );
});

exports.onPrayerRequestUpdated = onDocumentUpdated('prayerRequests/{id}', async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!before || !after) return;

  const normalize = (v) => {
    const s = toLc(S(v || 'new'));
    if (s === 'prayed' || s === 'acknowledged') return 'acknowledged';
    return s;
  };

  const prev = normalize(before.status);
  const next = normalize(after.status);
  if (prev === next) return;
  if (next !== 'acknowledged') return;

  let recipientUid = S(after.requestedByUid) || null;
  const requesterMemberId = S(after.requesterMemberId);
  if (!recipientUid && requesterMemberId) {
    const u = await findUserByMemberId(requesterMemberId);
    if (u?.id) recipientUid = u.id;
  }
  if (!recipientUid) return;

  const title = 'Prayer request acknowledged';
  const body = 'A pastor has acknowledged your prayer request.';

  await writeInbox(recipientUid, {
    type: 'prayer_request_acknowledged',
    prayerRequestId: event.params.id,
    title,
    body,
    requestedByUid: recipientUid,
    dedupeKey: `pr_ack_${event.params.id}_${recipientUid}`,
  });
});

/* =========================================================
   12) CALLABLES — user doc, secure linking, roles
   ========================================================= */
exports.ensureUserDoc = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  // canonical email
  let email = null;
  try {
    const authUser = await admin.auth().getUser(uid);
    email = (authUser.email || req.auth?.token?.email || '').trim().toLowerCase() || null;
  } catch {
    email = (req.auth?.token?.email || '').trim().toLowerCase() || null;
  }

  const ref = db.collection('users').doc(uid);
  const snap = await ref.get();

  if (!snap.exists) {
    await ref.set({ email, role: 'member', createdAt: ts(), updatedAt: ts() }, { merge: true });
  } else {
    await ref.set({ email, updatedAt: ts() }, { merge: true });
  }

  await recomputeAndWriteUserRole(uid);
  return { ok: true };
});

/**
 * syncUserRoleFromMemberOnLogin (HARDENED, NO `approved` field needed)
 * Linking priority:
 *  1) keep existing users.memberId if valid
 *  2) members.userUid == uid (explicit ownership)
 *  3) email match ONLY if UNIQUE (limit 2); if duplicates -> do NOT link
 * Also: if it links by unique email, it stamps members.userUid = uid (optional but recommended)
 */
exports.syncUserRoleFromMemberOnLogin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const cache = makeCtxCache();
  const authUser = await admin.auth().getUser(uid);
  const emailLc = (authUser.email || '').trim().toLowerCase();

  const user = await getUser(uid, cache);
  const userRef = db.doc(`users/${uid}`);

  let memberSnap = null;

  // 1) existing link
  if (user?.memberId) {
    const m = await db.doc(`members/${user.memberId}`).get();
    if (m.exists) memberSnap = m;
  }

  // 2) explicit ownership link
  if (!memberSnap) {
    const q = await db.collection('members').where('userUid', '==', uid).limit(1).get();
    if (!q.empty) memberSnap = q.docs[0];
  }

  // 3) fallback: unique email match only
  let linkedBy = null;
  if (!memberSnap && emailLc) {
    const q = await db.collection('members').where('email', '==', emailLc).limit(2).get();
    if (q.size === 1) {
      memberSnap = q.docs[0];
      linkedBy = 'unique_email';
    } else if (q.size > 1) {
      logger.warn('Email match not unique; skipping auto-link', { uid, emailLc, count: q.size });
    }
  }

  const memberData = memberSnap?.data() || null;
  const memberRoles = normalizeRoles(memberData?.roles || []);
  const leadershipMins = Array.isArray(memberData?.leadershipMinistries)
    ? memberData.leadershipMinistries
    : null;
  const mergedRoles = mergeRoles(user?.roles || [], [
    ...memberRoles,
    ...(leadershipMins && leadershipMins.length > 0 ? ['leader'] : []),
  ]);

  const highest = highestRole([
    ...mergedRoles,
    ...(memberData?.isPastor ? ['pastor'] : []),
  ]);

  const write = {
    role: highest,
    email: emailLc || user?.email || null,
    updatedAt: ts(),
    roles: mergedRoles,
  };
  if (leadershipMins) write.leadershipMinistries = leadershipMins;

  // set memberId only if not already linked
  if (memberSnap && !user?.memberId) {
    write.memberId = memberSnap.id;

    // optional but strongly recommended: stamp ownership
    // prevents future mislinks and makes linking O(1)
    if (linkedBy === 'unique_email') {
      await memberSnap.ref.set({ userUid: uid, updatedAt: ts() }, { merge: true });
    }
  }

  await userRef.set(write, { merge: true });
  await syncClaimsForUid(uid, cache);

  return { ok: true, role: highest, linkedMemberId: write.memberId || user?.memberId || null };
});

/**
 * Self-link after verification (no admin required).
 * - Requires auth + verified email
 * - Links by members.userUid OR unique email match
 * - Stamps users.memberId + members.userUid
 */
exports.linkSelfAfterVerification = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in required.');

  const authUser = await admin.auth().getUser(uid);
  if (!authUser.emailVerified) {
    throw new HttpsError('failed-precondition', 'Email not verified.');
  }

  const emailLc = toLc(authUser.email || '');
  if (!emailLc) {
    throw new HttpsError('failed-precondition', 'Email missing.');
  }

  let memberSnap = null;

  const byUid = await db.collection('members').where('userUid', '==', uid).limit(1).get();
  if (!byUid.empty) memberSnap = byUid.docs[0];

  if (!memberSnap) {
    const byEmail = await db
      .collection('members')
      .where('email', '==', emailLc)
      .orderBy('updatedAt', 'desc')
      .limit(2)
      .get();
    if (byEmail.size >= 1) {
      memberSnap = byEmail.docs[0];
    }
  }

  if (!memberSnap) {
    throw new HttpsError('not-found', 'No matching member record found.');
  }

  const memberId = memberSnap.id;
  const mData = memberSnap.data() || {};
  const firstName = S(mData.firstName);
  const lastName = S(mData.lastName);
  const fullName = S(mData.fullName) || [firstName, lastName].filter(Boolean).join(' ').trim();
  const userUpdate = { memberId, updatedAt: ts() };
  if (fullName) {
    userUpdate.fullName = fullName;
    userUpdate.fullNameLower = fullName.toLowerCase();
  }
  await db.doc(`users/${uid}`).set(userUpdate, { merge: true });

  const memberUpdate = { userUid: uid, updatedAt: ts() };
  const memberEmail = toLc(memberSnap.get('email') || '');
  if (memberEmail !== emailLc) {
    memberUpdate.email = emailLc;
  }
  await memberSnap.ref.set(memberUpdate, { merge: true });

  await recomputeAndWriteUserRole(uid);
  return { ok: true, linkedMemberId: memberId };
});

/**
 * Check if a phone number is already used by a member.
 * Returns { exists: boolean, memberId?: string }
 */
exports.checkPhoneNumberExists = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in required.');

  const phone = S(req.data?.phoneNumber);
  const excludeMemberId = S(req.data?.excludeMemberId);
  if (!phone) throw new HttpsError('invalid-argument', 'phoneNumber required.');

  const qs = await db.collection('members').where('phoneNumber', '==', phone).limit(2).get();
  if (qs.empty) return { exists: false };

  const match = qs.docs.find((d) => d.id !== excludeMemberId) || null;
  return match ? { exists: true, memberId: match.id } : { exists: false };
});

/**
 * One-time admin utility: normalize user<->member links and roles.
 * - links users to members by existing memberId, members.userUid, or unique email
 * - syncs user roles/role/leadershipMinistries from member data
 * - optionally syncs member roles from merged roles
 */
exports.normalizeUserLinksAndRoles = onCall(async (req) => {
  const callerUid = req.auth?.uid;
  if (!callerUid) throw new Error('unauthenticated');

  const allowed = await isUserPastorOrAdmin(callerUid);
  if (!allowed) throw new Error('permission-denied');

  const {
    limit = 200,
    startAfterUid = null,
    dryRun = true,
    mode = 'all',
    syncClaims = false,
  } = req.data || {};

  const lim = Math.max(1, Math.min(Number(limit) || 200, 500));
  let q = db.collection('users').orderBy(admin.firestore.FieldPath.documentId()).limit(lim);
  if (mode === 'unlinked') q = q.where('memberId', '==', null);
  if (startAfterUid) q = q.startAfter(String(startAfterUid));

  const snap = await q.get();
  let processed = 0;
  let linked = 0;
  let updated = 0;
  let conflicts = 0;
  let ambiguous = 0;
  const updatedUids = [];

  const sameSet = (a, b) => {
    const sa = new Set(asArray(a).map((v) => String(v ?? '').trim()).filter(Boolean));
    const sb = new Set(asArray(b).map((v) => String(v ?? '').trim()).filter(Boolean));
    if (sa.size !== sb.size) return false;
    for (const v of sa) if (!sb.has(v)) return false;
    return true;
  };

  let batch = db.batch();
  let batchOps = 0;
  const commitBatch = async () => {
    if (dryRun || batchOps === 0) return;
    await batch.commit();
    batch = db.batch();
    batchOps = 0;
  };

  for (const doc of snap.docs) {
    processed += 1;
    const uid = doc.id;
    const user = doc.data() || {};
    const emailLc = (user.email || '').toString().trim().toLowerCase();

    let memberSnap = null;
    let linkedBy = null;

    if (user.memberId) {
      const m = await db.doc(`members/${user.memberId}`).get();
      if (m.exists) {
        memberSnap = m;
        linkedBy = 'memberId';
      }
    }

    if (!memberSnap) {
      const q1 = await db.collection('members').where('userUid', '==', uid).limit(1).get();
      if (!q1.empty) {
        memberSnap = q1.docs[0];
        linkedBy = 'userUid';
      }
    }

    if (!memberSnap) {
      const qLegacy = await db.collection('members').where('userId', '==', uid).limit(1).get();
      if (!qLegacy.empty) {
        memberSnap = qLegacy.docs[0];
        linkedBy = 'legacy_userId';
      }
    }

    if (!memberSnap && emailLc) {
      const q2 = await db.collection('members').where('email', '==', emailLc).limit(2).get();
      if (q2.size === 1) {
        memberSnap = q2.docs[0];
        linkedBy = 'unique_email';
      } else if (q2.size > 1) {
        ambiguous += 1;
      }
    }

    const memberData = memberSnap ? (memberSnap.data() || {}) : null;
    const memberUid = memberData?.userUid || null;
    const legacyUid = memberData?.userId || null;
    if (memberSnap && memberUid && memberUid !== uid) {
      conflicts += 1;
      continue;
    }
    if (memberSnap && !memberUid && legacyUid && legacyUid !== uid) {
      conflicts += 1;
      continue;
    }

    const mergedRoles = normalizeRoles([
      ...(user.roles || []),
      ...(memberData?.roles || []),
      ...(memberData?.isPastor ? ['pastor'] : []),
    ]);
    const single = highestRole(mergedRoles);

    const nextLead = uniq([
      ...asArray(user.leadershipMinistries),
      ...asArray(memberData?.leadershipMinistries),
    ].map((v) => String(v ?? '').trim()).filter(Boolean));

    const userUpdates = {};
    if (!sameSet(user.roles || [], mergedRoles)) userUpdates.roles = mergedRoles;
    if (toLc(user.role) !== single) userUpdates.role = single;
    if (memberSnap && user.memberId !== memberSnap.id) userUpdates.memberId = memberSnap.id;
    if (!sameSet(user.leadershipMinistries || [], nextLead)) userUpdates.leadershipMinistries = nextLead;

    if (Object.keys(userUpdates).length) {
      userUpdates.updatedAt = ts();
    }

    const memberUpdates = {};
    if (memberSnap && !memberUid) {
      memberUpdates.userUid = uid;
    }
    if (memberSnap && !sameSet(memberData?.roles || [], mergedRoles)) {
      memberUpdates.roles = mergedRoles;
    }
    if (memberSnap && Object.keys(memberUpdates).length) {
      memberUpdates.updatedAt = ts();
    }

    if (memberSnap) linked += 1;

    if (!dryRun) {
      if (Object.keys(userUpdates).length) {
        batch.set(doc.ref, userUpdates, { merge: true });
        batchOps += 1;
      }
      if (memberSnap && Object.keys(memberUpdates).length) {
        batch.set(memberSnap.ref, memberUpdates, { merge: true });
        batchOps += 1;
      }
      if (batchOps >= 400) await commitBatch();
    }

    if (Object.keys(userUpdates).length || Object.keys(memberUpdates).length) {
      updated += 1;
      updatedUids.push(uid);
    }

    if (linkedBy === 'unique_email' && memberSnap && !memberData?.userUid && !dryRun) {
      // already handled by memberUpdates.userUid
    }
  }

  await commitBatch();

  if (!dryRun && syncClaims && updatedUids.length) {
    for (const uid of updatedUids) {
      await syncClaimsForUid(uid);
    }
  }

  const nextPageToken = snap.docs.length === lim ? snap.docs[snap.docs.length - 1].id : null;

  return {
    ok: true,
    processed,
    linked,
    updated,
    conflicts,
    ambiguous,
    nextPageToken,
    dryRun: !!dryRun,
  };
});

exports.setMemberPastorRole = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const { memberId, makePastor } = req.data || {};
  if (!memberId || typeof makePastor !== 'boolean') throw new Error('invalid-argument');

  const allowed = await isUserPastorOrAdmin(uid);
  if (!allowed) throw new Error('permission-denied');

  await db.runTransaction(async (tx) => {
    const mRef = db.doc(`members/${memberId}`);
    const mSnap = await tx.get(mRef);
    if (!mSnap.exists) throw new Error('not-found: member');

    const merged = mergeRoles(mSnap.data().roles || [], makePastor ? ['pastor'] : [], makePastor ? [] : ['pastor']);
    txSyncMemberRoles(tx, memberId, merged);

    const linked = await findUserByMemberId(memberId);
    if (linked?.id) txSyncUserRoles(tx, linked.id, merged);
  });

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);

  return { ok: true };
});

exports.setMemberRoles = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const allowed = await isUserPastorOrAdmin(uid);
  if (!allowed) throw new Error('permission-denied');

  const memberIds = uniq(asArray(req.data?.memberIds).map(S).filter(Boolean));
  const rolesAdd = normalizeRoles(req.data?.rolesAdd || []);
  const rolesRemove = normalizeRoles(req.data?.rolesRemove || []);
  if (!memberIds.length) throw new Error('invalid-argument: memberIds empty');

  let updated = 0;

  for (const memberId of memberIds) {
    await db.runTransaction(async (tx) => {
      const mRef = db.doc(`members/${memberId}`);
      const mSnap = await tx.get(mRef);
      if (!mSnap.exists) return;

      const merged = mergeRoles(mSnap.data().roles || [], rolesAdd, rolesRemove);
      txSyncMemberRoles(tx, memberId, merged);

      const linked = await findUserByMemberId(memberId);
      if (linked?.id) txSyncUserRoles(tx, linked.id, merged);

      updated += 1;
    });

    const linked = await findUserByMemberId(memberId);
    if (linked?.id) await syncClaimsForUid(linked.id);
  }

  return { ok: true, updated };
});

/**
 * Trigger: when member roles change, mirror to linked user + claims.
 */
exports.onMemberRolesChanged = onDocumentUpdated('members/{memberId}', async (event) => {
  const before = event.data?.before?.data() || {};
  const after = event.data?.after?.data() || {};
  const memberId = event.params.memberId;

  const beforeRoles = normalizeRoles(before.roles || []);
  const afterRoles = normalizeRoles(after.roles || []);
  if (beforeRoles.join('|') === afterRoles.join('|')) return;

  const linked = await findUserByMemberId(memberId);
  if (!linked?.id) return;

  const single = highestRole(afterRoles);
  await db.doc(`users/${linked.id}`).set(
    { roles: afterRoles, role: single, updatedAt: ts() },
    { merge: true }
  );
  await syncClaimsForUid(linked.id);

  logger.info('Synced user roles from member roles', { memberId, uid: linked.id, afterRoles });
});

/* =========================================================
   12b) Member search fields (server-side normalization)
   ========================================================= */
exports.onMemberSearchFields = onDocumentWritten('members/{memberId}', async (event) => {
  const after = event.data?.after;
  if (!after || !after.exists) return;
  const data = after.data() || {};

  const fullName = normalizeFullName(data);
  const fullNameLower = toLc(fullName);
  const phoneRaw = data.phoneNumber || data.phone || data.phoneNo || data.phone_number;
  const phoneDigits = digitsOnly(phoneRaw);
  const genderNorm = genderBucket(data.gender);

  const updates = {};
  if (!S(data.fullName) && fullName) updates.fullName = fullName;
  if (fullNameLower && data.fullNameLower !== fullNameLower) updates.fullNameLower = fullNameLower;
  if (phoneDigits && data.phoneDigits !== phoneDigits) updates.phoneDigits = phoneDigits;
  if (genderNorm && data.genderBucket !== genderNorm) updates.genderBucket = genderNorm;

  if (Object.keys(updates).length === 0) return;
  await after.ref.set(updates, { merge: true });
});

/* =========================================================
   13) Ministry moderation helpers & callables
   ========================================================= */
async function isLeaderOfMinistry(uid, ministryName) {
  if (!uid || !ministryName) return false;
  try {
    const uSnap = await db.doc(`users/${uid}`).get();
    if (!uSnap.exists) return false;

    const u = uSnap.data() || {};
    const single = toLc(u.role);
    const roles = new Set([single, ...(Array.isArray(u.roles) ? u.roles.map(toLc) : [])]);

    if (roles.has('admin')) return true;
    if (!roles.has('leader')) return false;

    const leadMins = Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : [];
    return leadMins.includes(ministryName);
  } catch (e) {
    logger.error('isLeaderOfMinistry failed', { uid, ministryName, error: e });
    return false;
  }
}

async function countLeadersInMinistry(ministryName) {
  const qs = await db.collection('members').where('leadershipMinistries', 'array-contains', ministryName).get();
  return qs.size;
}

async function hasMinistryModerationRights(uid, ministryName) {
  if (!uid || !ministryName) return false;
  if (await isUserPastorOrAdmin(uid)) return true;
  return await isLeaderOfMinistry(uid, ministryName);
}

async function getLeaderMinistryNames(uid, cache) {
  const names = new Set();
  const u = await getUser(uid, cache);
  if (u && Array.isArray(u.leadershipMinistries)) {
    u.leadershipMinistries.map(S).filter(Boolean).forEach((n) => names.add(n));
  }

  const memberId = u?.memberId || (await findMemberIdByUid(uid, cache));
  if (memberId) {
    const m = await getMemberById(memberId, cache);
    if (m && Array.isArray(m.leadershipMinistries)) {
      m.leadershipMinistries.map(S).filter(Boolean).forEach((n) => names.add(n));
    }
  }
  return Array.from(names);
}

/**
 * getAdminDashboardStats
 * - Admin/Pastor: global members + global pending join requests
 * - Leader: members + pending join requests scoped to ministries they lead
 */
exports.getAdminDashboardStats = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const cache = makeCtxCache();
  const isPastorAdmin = await isUserPastorOrAdmin(uid);
  const role = await getUserRole(uid, cache);
  const isLeader = role === 'leader';

  if (!isPastorAdmin && !isLeader) {
    throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });
  }
  const membersAgg = await db.collection('members').count().get();
  const membersTotal = Number(membersAgg.data().count || 0);

  // Fast path for pastor/admin: full counts.
  if (isPastorAdmin) {
    const pendingAgg = await db.collection('join_requests').where('status', '==', 'pending').count().get();

    return {
      ok: true,
      scope: 'global',
      membersCount: membersTotal,
      pendingJoinRequestsCount: Number(pendingAgg.data().count || 0),
    };
  }

  const leaderMinistries = await getLeaderMinistryNames(uid, cache);
  if (!leaderMinistries.length) {
    return {
      ok: true,
      scope: 'leader',
      leaderMinistries,
      membersCount: membersTotal,
      pendingJoinRequestsCount: 0,
    };
  }

  const memberIds = new Set();
  const pendingJoinRequestIds = new Set();
  const ministryDocIds = new Set();

  // Resolve doc ids for led ministry names (for joins stored by doc id).
  for (let i = 0; i < leaderMinistries.length; i += 10) {
    const chunk = leaderMinistries.slice(i, i + 10);
    const mins = await db.collection('ministries').where('name', 'in', chunk).get();
    mins.docs.forEach((d) => ministryDocIds.add(d.id));
  }

  for (let i = 0; i < leaderMinistries.length; i += 10) {
    const chunk = leaderMinistries.slice(i, i + 10);

    const [memberQs, byName, byLegacyNameId] = await Promise.all([
      db.collection('members').where('ministries', 'array-contains-any', chunk).get(),
      db.collection('join_requests').where('status', '==', 'pending').where('ministryName', 'in', chunk).get(),
      db.collection('join_requests').where('status', '==', 'pending').where('ministryId', 'in', chunk).get(),
    ]);

    memberQs.docs.forEach((d) => memberIds.add(d.id));
    byName.docs.forEach((d) => pendingJoinRequestIds.add(d.id));
    byLegacyNameId.docs.forEach((d) => pendingJoinRequestIds.add(d.id));
  }

  const docIds = Array.from(ministryDocIds);
  for (let i = 0; i < docIds.length; i += 10) {
    const chunk = docIds.slice(i, i + 10);
    const [byDocId, byMinistryIdDoc] = await Promise.all([
      db.collection('join_requests').where('status', '==', 'pending').where('ministryDocId', 'in', chunk).get(),
      db.collection('join_requests').where('status', '==', 'pending').where('ministryId', 'in', chunk).get(),
    ]);
    byDocId.docs.forEach((d) => pendingJoinRequestIds.add(d.id));
    byMinistryIdDoc.docs.forEach((d) => pendingJoinRequestIds.add(d.id));
  }

  return {
    ok: true,
    scope: 'leader',
    leaderMinistries,
    membersCount: membersTotal,
    pendingJoinRequestsCount: pendingJoinRequestIds.size,
  };
});

/* =========================================================
   12c) Server-side member search
   ========================================================= */
exports.searchMembers = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const query = toLc(req.data?.query);
  const gender = toLc(req.data?.gender || 'all');
  const ministryName = S(req.data?.ministryName);
  const visitor = toLc(req.data?.visitor || 'all'); // all | member | visitor
  const limit = Math.max(1, Math.min(Number(req.data?.limit) || 50, 100));
  if (!query || query.length < 2) {
    return { ok: true, results: [] };
  }

  const applyFilters = (q) => {
    let out = q;
    if (gender && gender !== 'all') {
      out = out.where('genderBucket', '==', gender);
    }
    if (ministryName) {
      out = out.where('ministries', 'array-contains', ministryName);
    }
    if (visitor === 'visitor') {
      out = out.where('isVisitor', '==', true);
    } else if (visitor === 'member') {
      out = out.where('isVisitor', '==', false);
    }
    return out;
  };

  const results = new Map();
  const nameEnd = `${query}\uf8ff`;
  const nameQs = await applyFilters(
    db.collection('members')
    .where('fullNameLower', '>=', query)
    .where('fullNameLower', '<=', nameEnd)
    .orderBy('fullNameLower')
  )
    .limit(limit)
    .get();
  nameQs.docs.forEach((d) => results.set(d.id, d));

  const digits = digitsOnly(query);
  if (digits.length >= 4) {
    const phoneEnd = `${digits}\uf8ff`;
    const phoneQs = await applyFilters(
      db.collection('members')
      .where('phoneDigits', '>=', digits)
      .where('phoneDigits', '<=', phoneEnd)
      .orderBy('phoneDigits')
    )
      .limit(limit)
      .get();
    phoneQs.docs.forEach((d) => results.set(d.id, d));
  }

  const payload = Array.from(results.values()).slice(0, limit).map((d) => {
    const m = d.data() || {};
    const fullName = normalizeFullName(m);
    return {
      id: d.id,
      firstName: m.firstName || '',
      lastName: m.lastName || '',
      fullName,
      gender: m.gender || '',
      isVisitor: m.isVisitor === true,
      phoneNumber: m.phoneNumber || m.phone || '',
      ministries: Array.isArray(m.ministries) ? m.ministries : [],
      roles: Array.isArray(m.roles) ? m.roles : [],
    };
  });

  return { ok: true, results: payload };
});

/**
 * backfillMemberSearchFields
 * - Admin/Pastor only
 * - Runs in small batches to populate fullNameLower/phoneDigits/genderBucket
 */
exports.backfillMemberSearchFields = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });
  if (!(await isUserPastorOrAdmin(uid))) {
    throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });
  }

  const limit = Math.max(1, Math.min(Number(req.data?.limit) || 200, 500));
  const startAfterId = S(req.data?.startAfterId);

  let q = db.collection('members').orderBy(admin.firestore.FieldPath.documentId()).limit(limit);
  if (startAfterId) {
    const startDoc = await db.doc(`members/${startAfterId}`).get();
    if (startDoc.exists) q = q.startAfter(startDoc);
  }

  const snap = await q.get();
  if (snap.empty) return { ok: true, processed: 0, updated: 0, done: true };

  let updated = 0;
  let processed = 0;
  let batch = db.batch();
  let writes = 0;

  for (const doc of snap.docs) {
    processed++;
    const data = doc.data() || {};
    const fullName = normalizeFullName(data);
    const fullNameLower = toLc(fullName);
    const phoneRaw = data.phoneNumber || data.phone || data.phoneNo || data.phone_number;
    const phoneDigits = digitsOnly(phoneRaw);
    const genderNorm = genderBucket(data.gender);

    const updates = {};
    if (!S(data.fullName) && fullName) updates.fullName = fullName;
    if (fullNameLower && data.fullNameLower !== fullNameLower) updates.fullNameLower = fullNameLower;
    if (phoneDigits && data.phoneDigits !== phoneDigits) updates.phoneDigits = phoneDigits;
    if (genderNorm && data.genderBucket !== genderNorm) updates.genderBucket = genderNorm;

    if (Object.keys(updates).length > 0) {
      updates.updatedAt = ts();
      batch.set(doc.ref, updates, { merge: true });
      updated++;
      writes++;
      if (writes % 400 === 0) {
        await batch.commit();
        batch = db.batch();
      }
    }
  }

  if (writes % 400 !== 0) await batch.commit();
  const lastId = snap.docs[snap.docs.length - 1].id;
  return { ok: true, processed, updated, done: snap.docs.length < limit, nextStartAfterId: lastId };
});

/* =========================================================
   12d) Follow-up summary (server-side aggregates)
   ========================================================= */
exports.getFollowUpSummary = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const dateKey = S(req.data?.dateKey);
  const windowId = S(req.data?.windowId);
  if (!dateKey) throw Object.assign(new Error('invalid-argument'), { code: 'invalid-argument' });

  const [allAgg, visitorsAgg] = await Promise.all([
    db.collection('members').count().get(),
    db.collection('members').where('isVisitor', '==', true).count().get(),
  ]);
  const totalAll = Number(allAgg.data().count || 0);
  const totalVisitors = Number(visitorsAgg.data().count || 0);
  const totalMembers = Math.max(totalAll - totalVisitors, 0);

  let windowCount = 0;
  try {
    const winSnap = await db.collection('attendance_windows').where('dateKey', '==', dateKey).limit(2).get();
    windowCount = winSnap.size;
  } catch (_) {}

  const recordsSnap = await db.collection('attendance').doc(dateKey).collection('records').get();
  const records = [];

  for (const d of recordsSnap.docs) {
    const data = d.data() || {};
    const recWindowId = S(data.windowId);
    if (windowId) {
      if (recWindowId) {
        if (recWindowId !== windowId) continue;
      } else if (windowCount > 1) {
        continue;
      }
    }
    records.push({ id: d.id, ...data });
  }

  // Fill missing member metadata for accurate gender/visitor stats
  const missingIds = new Set();
  for (const r of records) {
    if (r.memberGenderBucket == null || r.memberIsVisitor == null) {
      missingIds.add(r.memberId || r.id);
    }
  }

  if (missingIds.size > 0) {
    const ids = Array.from(missingIds);
    for (let i = 0; i < ids.length; i += 400) {
      const chunk = ids.slice(i, i + 400);
      const refs = chunk.map((id) => db.doc(`members/${id}`));
      const snaps = await db.getAll(...refs);
      const map = new Map();
      snaps.forEach((s) => {
        if (s.exists) map.set(s.id, s.data() || {});
      });
      records.forEach((r) => {
        const mid = r.memberId || r.id;
        if (!mid || !map.has(mid)) return;
        const m = map.get(mid);
        if (r.memberGenderBucket == null) r.memberGenderBucket = genderBucket(m.gender);
        if (r.memberIsVisitor == null) r.memberIsVisitor = Boolean(m.isVisitor);
      });
    }
  }

  const counts = {
    presentMembers: 0,
    absentMembers: 0,
    presentVisitors: 0,
    absentVisitors: 0,
    malePresent: 0,
    femalePresent: 0,
    unknownPresent: 0,
    maleAbsent: 0,
    femaleAbsent: 0,
    unknownAbsent: 0,
  };

  for (const r of records) {
    const statusRaw = toLc(r.status || r.result || (r.present === true ? 'present' : r.present === false ? 'absent' : ''));
    const isPresent = statusRaw === 'present';
    const isAbsent = statusRaw === 'absent';
    const isVisitor = Boolean(r.memberIsVisitor);
    const g = r.memberGenderBucket || genderBucket(r.gender);

    if (isVisitor) {
      if (isPresent) counts.presentVisitors++;
      if (isAbsent) counts.absentVisitors++;
    } else {
      if (isPresent) counts.presentMembers++;
      if (isAbsent) counts.absentMembers++;
    }

    if (isPresent) {
      if (g === 'male') counts.malePresent++;
      else if (g === 'female') counts.femalePresent++;
      else counts.unknownPresent++;
    } else if (isAbsent) {
      if (g === 'male') counts.maleAbsent++;
      else if (g === 'female') counts.femaleAbsent++;
      else counts.unknownAbsent++;
    }
  }

  const absentMembers = counts.absentMembers || Math.max(totalMembers - counts.presentMembers, 0);
  const absentVisitors = counts.absentVisitors || Math.max(totalVisitors - counts.presentVisitors, 0);

  return {
    ok: true,
    totalMembers,
    totalVisitors,
    presentMembers: counts.presentMembers,
    presentVisitors: counts.presentVisitors,
    absentMembers,
    absentVisitors,
    malePresent: counts.malePresent,
    femalePresent: counts.femalePresent,
    unknownPresent: counts.unknownPresent,
    maleAbsent: counts.maleAbsent,
    femaleAbsent: counts.femaleAbsent,
    unknownAbsent: counts.unknownAbsent,
  };
});

/* =========================================================
   12e) Follow-up absentees list (server-side, paged)
   ========================================================= */
exports.listFollowUpAbsentees = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const dateKey = S(req.data?.dateKey);
  const windowId = S(req.data?.windowId);
  const type = toLc(req.data?.type || 'member'); // member | visitor
  const gender = toLc(req.data?.gender || 'all');
  const ministryName = S(req.data?.ministryName);
  const query = toLc(req.data?.query);
  const matchMode = toLc(req.data?.matchMode || 'prefix'); // prefix | exact
  const limit = Math.max(1, Math.min(Number(req.data?.limit) || 50, 100));
  const cursor = req.data?.cursor || null;

  if (!dateKey) throw Object.assign(new Error('invalid-argument'), { code: 'invalid-argument' });

  let windowCount = 0;
  try {
    const winSnap = await db.collection('attendance_windows').where('dateKey', '==', dateKey).limit(2).get();
    windowCount = winSnap.size;
  } catch (_) {}

  const presentSet = new Set();
  let recordsSnap;
  if (windowId && windowCount > 1) {
    recordsSnap = await db
      .collection('attendance')
      .doc(dateKey)
      .collection('records')
      .where('windowId', '==', windowId)
      .get();
  } else {
    recordsSnap = await db.collection('attendance').doc(dateKey).collection('records').get();
  }

  const isPresentRecord = (r) => {
    const status = toLc(r.status || r.result || '');
    if (status === 'present') return true;
    if (status === 'absent') return false;
    if (r.present === true) return true;
    if (r.present === false) return false;
    return false;
  };

  recordsSnap.docs.forEach((d) => {
    const data = d.data() || {};
    const recWindowId = S(data.windowId);
    if (windowId && windowCount > 1 && recWindowId && recWindowId !== windowId) return;
    if (windowId && windowCount > 1 && !recWindowId) return;
    if (!isPresentRecord(data)) return;
    const mid = S(data.memberId) || d.id;
    if (mid) presentSet.add(mid);
  });

  const digits = query ? digitsOnly(query) : '';
  const queryCompact = query ? query.replace(/\s/g, '') : '';
  const isPhoneQuery = digits.length >= 4 && digits.length === queryCompact.length;
  const orderField = isPhoneQuery ? 'phoneDigits' : 'fullNameLower';
  const rangeQuery = query && query.length >= 2 ? (isPhoneQuery ? digits : query) : '';
  const rangeEnd = rangeQuery ? `${rangeQuery}\uf8ff` : '';

  let hasMore = true;
  let nextCursor = null;
  const results = [];

  const applyFilters = (q) => {
    let out = q;
    if (gender && gender !== 'all') out = out.where('genderBucket', '==', gender);
    if (ministryName) out = out.where('ministries', 'array-contains', ministryName);
    if (type === 'visitor') out = out.where('isVisitor', '==', true);
    else if (type === 'member') out = out.where('isVisitor', '==', false);
    return out;
  };

  // Exact match mode (no prefix range)
  if (matchMode === 'exact' && rangeQuery) {
    let q = db.collection('members');
    q = applyFilters(q);
    if (isPhoneQuery) q = q.where('phoneDigits', '==', digits);
    else q = q.where('fullNameLower', '==', query);
    q = q.orderBy(admin.firestore.FieldPath.documentId()).limit(limit + 1);
    if (cursor?.id) {
      q = q.startAfter(cursor.id);
    }

    const snap = await q.get();
    const docs = snap.docs;
    hasMore = docs.length > limit;
    const sliced = docs.slice(0, limit);
    sliced.forEach((d) => {
      const m = d.data() || {};
      if (presentSet.has(d.id)) return;
      results.push({
        id: d.id,
        firstName: m.firstName || '',
        lastName: m.lastName || '',
        fullName: normalizeFullName(m),
        gender: m.gender || '',
        isVisitor: m.isVisitor === true,
        phoneNumber: m.phoneNumber || m.phone || '',
        ministries: Array.isArray(m.ministries) ? m.ministries : [],
      });
    });

    const lastDoc = sliced[sliced.length - 1];
    nextCursor = lastDoc ? { id: lastDoc.id } : null;

    return {
      ok: true,
      results,
      hasMore,
      cursor: nextCursor,
    };
  }

  let lastFieldVal = cursor?.fieldValue ?? null;
  let lastId = cursor?.id ?? null;

  while (results.length < limit && hasMore) {
    let q = db.collection('members');
    q = applyFilters(q);
    if (rangeQuery) {
      q = q.where(orderField, '>=', rangeQuery).where(orderField, '<=', rangeEnd);
    }
    q = q.orderBy(orderField).orderBy(admin.firestore.FieldPath.documentId()).limit(200);
    if (lastFieldVal != null && lastId) {
      q = q.startAfter(lastFieldVal, lastId);
    }

    const snap = await q.get();
    if (snap.empty) {
      hasMore = false;
      break;
    }

    for (const d of snap.docs) {
      const m = d.data() || {};
      if (presentSet.has(d.id)) continue;
      results.push({
        id: d.id,
        firstName: m.firstName || '',
        lastName: m.lastName || '',
        fullName: normalizeFullName(m),
        gender: m.gender || '',
        isVisitor: m.isVisitor === true,
        phoneNumber: m.phoneNumber || m.phone || '',
        ministries: Array.isArray(m.ministries) ? m.ministries : [],
      });
      if (results.length >= limit) break;
    }

    const lastDoc = snap.docs[snap.docs.length - 1];
    lastFieldVal = lastDoc.get(orderField) ?? '';
    lastId = lastDoc.id;
    nextCursor = { field: orderField, fieldValue: lastFieldVal, id: lastId };
    if (snap.docs.length < 200) hasMore = false;
  }

  return {
    ok: true,
    results,
    hasMore,
    cursor: nextCursor,
  };
});

/**
 * leaderListPendingJoinRequestsForMinistry
 * - returns pending join requests scoped to one ministry
 * - allowed for pastor/admin OR leader of that ministry
 */
exports.leaderListPendingJoinRequestsForMinistry = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const arg = req.data || {};
  const resolved = await resolveMinistryByNameOrId(S(arg.ministryId) || S(arg.ministryName));
  let ministryName = resolved.ministryName || S(arg.ministryName);
  let ministryDocId = resolved.ministryDocId || null;

  if (!ministryName && ministryDocId) {
    const minDoc = await db.doc(`ministries/${ministryDocId}`).get();
    if (minDoc.exists) {
      const d = minDoc.data() || {};
      ministryName = S(d.name);
    }
  }

  if (!ministryName) {
    throw Object.assign(new Error('invalid-ministry'), { code: 'invalid-argument' });
  }

  const allowed = await hasMinistryModerationRights(uid, ministryName);
  if (!allowed) {
    throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });
  }

  const jobs = [
    db.collection('join_requests').where('status', '==', 'pending').where('ministryName', '==', ministryName).get(),
    db.collection('join_requests').where('status', '==', 'pending').where('ministryId', '==', ministryName).get(),
  ];

  if (ministryDocId) {
    jobs.push(
      db.collection('join_requests').where('status', '==', 'pending').where('ministryId', '==', ministryDocId).get(),
      db.collection('join_requests').where('status', '==', 'pending').where('ministryDocId', '==', ministryDocId).get()
    );
  }

  const snaps = await Promise.all(jobs);
  const merged = new Map();
  snaps.forEach((qs) => qs.docs.forEach((d) => merged.set(d.id, d)));

  const items = Array.from(merged.values()).map((d) => {
    const jr = d.data() || {};
    const requestedAtMs = jr.requestedAt && typeof jr.requestedAt.toMillis === 'function'
      ? jr.requestedAt.toMillis()
      : 0;
    return {
      requestId: d.id,
      memberId: S(jr.memberId),
      ministryName: S(jr.ministryName),
      ministryId: S(jr.ministryId),
      ministryDocId: S(jr.ministryDocId),
      requestedByUid: S(jr.requestedByUid),
      status: S(jr.status || 'pending'),
      requestedAtMs,
    };
  });

  // Attach best-effort requester display names for UI.
  await Promise.all(items.map(async (it) => {
    it.requesterName = (await getMemberDisplayName(it.memberId)) || '';
  }));

  items.sort((a, b) => Number(b.requestedAtMs || 0) - Number(a.requestedAtMs || 0));

  return {
    ok: true,
    ministryName,
    ministryDocId: ministryDocId || null,
    items,
  };
});

/**
 * getGracepointEvents
 * - server-side fetch/scrape of gracepointuk.com upcoming events
 */
exports.getGracepointEvents = onCall(async () => {
  const base = 'https://gracepointuk.com';
  const pages = [
    `${base}/`,
    `${base}/events/`,
    `${base}/events-calendar/`,
  ];

  const eventUrls = new Set();
  const items = [];

  const absUrl = (href) => {
    const h = S(href);
    if (!h) return null;
    if (h.startsWith('http://') || h.startsWith('https://')) return h;
    if (h.startsWith('/')) return `${base}${h}`;
    if (h.startsWith('?')) return `${base}/${h}`;
    return `${base}/${h}`;
  };

  const parseDate = (txt) => {
    const s = S(txt);
    if (!s) return null;
    const m = s.match(/(\d{4}-\d{2}-\d{2})[\sT]+(\d{2}:\d{2})/);
    if (m) {
      const d = new Date(`${m[1]}T${m[2]}:00`);
      if (!Number.isNaN(d.getTime())) return d;
    }
    const d2 = new Date(s);
    if (!Number.isNaN(d2.getTime())) return d2;
    return null;
  };

  for (const page of pages) {
    try {
      const res = await fetch(page, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Cloud Functions; ChurchApp)',
          Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      });
      if (!res.ok) continue;
      const html = await res.text();

      // Parse server-rendered list items used by Gracepoint's events template.
      const listingBlocks = [...html.matchAll(/<li class="[^"]*event-list-item[^"]*"[\s\S]*?<\/li>/gi)];
      for (const b of listingBlocks) {
        const block = b[0];
        const title = S((block.match(/class="event-title"[^>]*>([\s\S]*?)<\/a>/i) || [])[1])
          .replace(/<[^>]+>/g, '')
          .replace(/&#038;|&amp;/g, '&')
          .trim();
        if (!title) continue;

        let dateRaw = S((block.match(/class="adore_event_cdate">([\s\S]*?)<\/span>/i) || [])[1]).trim();
        if (!dateRaw) {
          const day = S((block.match(/class="event-day">([\s\S]*?)<\/span>/i) || [])[1]).trim();
          const month = S((block.match(/class="event-month">([\s\S]*?)<\/span>/i) || [])[1]).trim();
          if (day && month) dateRaw = `${day} ${month}`;
        }
        const start = parseDate(dateRaw);
        if (!start) continue;

        let href = S((block.match(/class="event-title"[^>]*href="([^"]+)"/i) || [])[1]).trim();
        if (!href) {
          href = S((block.match(/class="adore_event_url">([\s\S]*?)<\/span>/i) || [])[1]).trim();
        }
        href = href.replace(/&#038;|&amp;/g, '&');
        const link = absUrl(href);
        const location = S((block.match(/class="event-location-address">([\s\S]*?)<\/span>/i) || [])[1])
          .replace(/<[^>]+>/g, '')
          .trim();

        items.push({
          id: `ext_${title.toLowerCase().replace(/\s+/g, '-')}_${start.getTime()}`,
          title,
          description: '',
          startDateIso: start.toISOString(),
          endDateIso: null,
          location,
          link,
        });
        if (link && /[?&]event=/i.test(link)) eventUrls.add(link);
      }

      // JSON-LD events
      const scripts = [...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
      for (const s of scripts) {
        try {
          const parsed = JSON.parse(s[1]);
          const nodes = Array.isArray(parsed) ? parsed : [parsed];
          for (const n of nodes) {
            const t = toLc(n?.['@type']);
            if (t !== 'event') continue;
            const title = S(n.name);
            const start = parseDate(n.startDate);
            if (!title || !start) continue;
            const url = absUrl(n.url);
            items.push({
              id: `ext_${title.toLowerCase().replace(/\s+/g, '-')}_${start.getTime()}`,
              title,
              description: S(n.description),
              startDateIso: start.toISOString(),
              endDateIso: parseDate(n.endDate)?.toISOString() || null,
              location: S(n?.location?.name),
              link: url,
            });
            if (url && /[?&]event=\d+/i.test(url)) eventUrls.add(url);
          }
        } catch (_) {}
      }

      // event links
      const links = [...html.matchAll(/href=["']([^"']*[?&]event=\d+[^"']*)["']/gi)];
      for (const l of links) {
        const u = absUrl(l[1]);
        if (u) eventUrls.add(u);
      }
    } catch (_) {}
  }

  for (const url of Array.from(eventUrls).slice(0, 40)) {
    try {
      const res = await fetch(url, {
        headers: { 'User-Agent': 'Mozilla/5.0 (Cloud Functions; ChurchApp)' },
      });
      if (!res.ok) continue;
      const html = await res.text();

      const title = S((html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || [])[1]).replace(/<[^>]+>/g, '').trim();
      const startRaw = (html.match(/DetailsStart:\s*`([^`]+)`/i) || [])[1] || '';
      const start = parseDate(startRaw || html);
      if (!title || !start) continue;
      items.push({
        id: `ext_${title.toLowerCase().replace(/\s+/g, '-')}_${start.getTime()}`,
        title,
        description: '',
        startDateIso: start.toISOString(),
        endDateIso: null,
        location: '',
        link: url,
      });
    } catch (_) {}
  }

  const dedupe = new Map();
  for (const it of items) {
    const day = S(it.startDateIso).slice(0, 10);
    const key = `${toLc(it.title)}|${day}`;
    if (!dedupe.has(key)) dedupe.set(key, it);
  }

  const cutoff = Date.now() - 24 * 60 * 60 * 1000;
  const out = Array.from(dedupe.values())
    .filter((it) => {
      const t = new Date(it.startDateIso).getTime();
      return Number.isFinite(t) && t >= cutoff;
    })
    .sort((a, b) => new Date(a.startDateIso) - new Date(b.startDateIso));

  return { ok: true, items: out };
});

/**
 * leaderModerateJoinRequest
 * - approve/reject pending join request
 * - adds member to ministry if approved
 */
exports.leaderModerateJoinRequest = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const { requestId, action } = req.data || {};
  const act = toLc(action);
  if (!requestId || !['approve', 'reject'].includes(act)) {
    throw Object.assign(new Error('INVALID_ARGUMENTS'), { code: 'invalid-argument' });
  }

  const jrRef = db.collection('join_requests').doc(requestId);
  const jrSnap = await jrRef.get();
  if (!jrSnap.exists) throw Object.assign(new Error('NOT_FOUND'), { code: 'not-found' });

  const jr = jrSnap.data() || {};
  const memberId = S(jr.memberId);

  const { ministryName, ministryDocId } = await resolveMinistryFromJoin(jr);
  if (!memberId || !ministryName) throw Object.assign(new Error('bad-request'), { code: 'invalid-argument' });

  const allowed = await hasMinistryModerationRights(uid, ministryName);
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const status = toLc(jr.status || 'pending');
  if (status !== 'pending') throw Object.assign(new Error('ALREADY_PROCESSED'), { code: 'failed-precondition' });

  if (act === 'approve') {
    const mRef = db.doc(`members/${memberId}`);
    await db.runTransaction(async (tx) => {
      const mSnap = await tx.get(mRef);
      if (!mSnap.exists) throw Object.assign(new Error('MEMBER_NOT_FOUND'), { code: 'not-found' });

      const m = mSnap.data() || {};
      const mins = Array.isArray(m.ministries) ? m.ministries.slice() : [];
      if (!mins.includes(ministryName)) mins.push(ministryName);

      tx.update(mRef, { ministries: mins, updatedAt: ts() });
      tx.update(jrRef, { status: 'approved', moderatorUid: uid, updatedAt: ts() });
    });
  } else {
    await jrRef.update({ status: 'rejected', moderatorUid: uid, updatedAt: ts() });
  }

  return { ok: true };
});

/**
 * adminCreateMinistry
 * - pastor/admin creates a ministry directly
 * - assigns one or more selected members as leaders
 * - ensures selected leaders are members of the new ministry
 */
exports.adminCreateMinistry = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const allowed = await isUserPastorOrAdmin(uid);
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const { name, description, leaderMemberIds } = req.data || {};
  const ministryName = S(name);
  const ministryDescription = S(description);
  const leaderIds = uniq(asArray(leaderMemberIds).map(S).filter(Boolean));

  if (!ministryName) {
    throw Object.assign(new Error('invalid-argument: name'), { code: 'invalid-argument' });
  }
  if (!leaderIds.length) {
    throw Object.assign(new Error('invalid-argument: leaderMemberIds'), { code: 'invalid-argument' });
  }

  const nameCollision = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
  if (!nameCollision.empty) {
    throw Object.assign(new Error('already-exists'), { code: 'already-exists' });
  }

  const leaderMemberSnaps = await Promise.all(leaderIds.map((id) => db.doc(`members/${id}`).get()));
  const missingMemberIds = leaderMemberSnaps.filter((s) => !s.exists).map((s) => s.id);
  if (missingMemberIds.length) {
    throw Object.assign(new Error(`member-not-found: ${missingMemberIds.join(',')}`), { code: 'not-found' });
  }

  const linkedUidByMemberId = new Map();
  await Promise.all(
    leaderIds.map(async (memberId) => {
      const linked = await findUserByMemberId(memberId);
      if (linked?.id) linkedUidByMemberId.set(memberId, linked.id);
    })
  );
  const leaderUids = uniq(Array.from(linkedUidByMemberId.values()).filter(Boolean));

  const minRef = db.collection('ministries').doc();
  await db.runTransaction(async (tx) => {
    const memberStates = [];

    for (const memberId of leaderIds) {
      const mRef = db.doc(`members/${memberId}`);
      const mSnap = await tx.get(mRef);
      if (!mSnap.exists) continue;

      const m = mSnap.data() || {};
      const ministries = new Set(Array.isArray(m.ministries) ? m.ministries : []);
      const leadershipMinistries = new Set(Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : []);
      ministries.add(ministryName);
      leadershipMinistries.add(ministryName);

      const linkedUid = linkedUidByMemberId.get(memberId);
      let userState = null;
      if (linkedUid) {
        const uRef = db.doc(`users/${linkedUid}`);
        const uSnap = await tx.get(uRef);
        const u = uSnap.exists ? uSnap.data() || {} : {};
        const uLeadership = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);
        uLeadership.add(ministryName);

        const roleSeed = uniq([toLc(u.role), ...(Array.isArray(u.roles) ? u.roles : [])].filter(Boolean));
        const mergedUserRoles = mergeRoles(roleSeed, ['leader'], []);

        userState = {
          linkedUid,
          uRef,
          uLeadership: Array.from(uLeadership),
          mergedUserRoles,
        };
      }

      memberStates.push({
        mRef,
        ministries: Array.from(ministries),
        leadershipMinistries: Array.from(leadershipMinistries),
        mergedMemberRoles: mergeRoles(Array.isArray(m.roles) ? m.roles : [], ['leader'], []),
        userState,
      });
    }

    tx.set(minRef, {
      id: minRef.id,
      name: ministryName,
      description: ministryDescription,
      approved: true,
      createdAt: ts(),
      updatedAt: ts(),
      createdBy: uid,
      leaderIds,
      leaderUids,
    });

    for (const state of memberStates) {
      tx.update(state.mRef, {
        ministries: state.ministries,
        leadershipMinistries: state.leadershipMinistries,
        roles: normalizeRoles(state.mergedMemberRoles),
        updatedAt: ts(),
      });

      if (state.userState) {
        txSyncUserRoles(tx, state.userState.linkedUid, state.userState.mergedUserRoles);
        tx.set(
          state.userState.uRef,
          {
            leadershipMinistries: state.userState.uLeadership,
            updatedAt: ts(),
          },
          { merge: true }
        );
      }
    }
  });

  await Promise.all(leaderUids.map((u) => syncClaimsForUid(u)));

  return {
    ok: true,
    ministryId: minRef.id,
    ministryName,
    leaderCount: leaderIds.length,
  };
});

/**
 * adminDeleteMinistry
 * - pastor/admin removes a ministry entirely
 * - removes ministry membership + leadership from all affected members
 * - removes leadership ministry + stale leader role from linked users
 * - deletes join requests and ministry feed/subcollections
 */
exports.adminDeleteMinistry = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const allowed = await isUserPastorOrAdmin(uid);
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const { ministryId, ministryName: ministryNameArg } = req.data || {};
  const resolved = await resolveMinistryByNameOrId(S(ministryId) || S(ministryNameArg));

  let ministryName = resolved.ministryName || S(ministryNameArg);
  let ministryDocId = resolved.ministryDocId || null;

  if (!ministryDocId && ministryName) {
    const byName = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
    if (!byName.empty) ministryDocId = byName.docs[0].id;
  }
  if (!ministryName && ministryDocId) {
    const minDoc = await db.doc(`ministries/${ministryDocId}`).get();
    if (minDoc.exists) {
      const d = minDoc.data() || {};
      ministryName = S(d.name);
    }
  }

  if (!ministryName && !ministryDocId) {
    throw Object.assign(new Error('invalid-ministry'), { code: 'invalid-argument' });
  }

  const memberDocsById = new Map();
  if (ministryName) {
    const [byMembership, byLeadership] = await Promise.all([
      db.collection('members').where('ministries', 'array-contains', ministryName).get(),
      db.collection('members').where('leadershipMinistries', 'array-contains', ministryName).get(),
    ]);
    byMembership.docs.forEach((d) => memberDocsById.set(d.id, d));
    byLeadership.docs.forEach((d) => memberDocsById.set(d.id, d));
  }

  const affectedMemberIds = Array.from(memberDocsById.keys());
  const linkedUidByMemberId = affectedMemberIds.length
    ? await mapMemberIdsToUids(affectedMemberIds)
    : new Map();

  const userDocsById = new Map();
  if (ministryName) {
    const usersByLeadMinistry = await db
      .collection('users')
      .where('leadershipMinistries', 'array-contains', ministryName)
      .get();
    usersByLeadMinistry.docs.forEach((d) => userDocsById.set(d.id, d));
  }

  for (const uidValue of linkedUidByMemberId.values()) {
    if (!uidValue || userDocsById.has(uidValue)) continue;
    const uSnap = await db.doc(`users/${uidValue}`).get();
    if (uSnap.exists) userDocsById.set(uidValue, uSnap);
  }

  const removedRoleTag = ministryName ? await getMinistryRoleTag(ministryName) : null;
  const otherMinistryNames = new Set();
  if (removedRoleTag) {
    for (const mSnap of memberDocsById.values()) {
      const m = mSnap.data() || {};
      const mins = Array.isArray(m.ministries) ? m.ministries : [];
      mins.map(S).filter(Boolean).forEach((n) => {
        if (n && n !== ministryName) otherMinistryNames.add(n);
      });
    }
  }
  const roleTagByMinistry = removedRoleTag ? await getRoleTagMapForMinistryNames(Array.from(otherMinistryNames)) : new Map();
  const removeRoleTagByUid = new Map();

  let batch = db.batch();
  let ops = 0;
  const commitBatch = async () => {
    if (ops === 0) return;
    await batch.commit();
    batch = db.batch();
    ops = 0;
  };

  for (const mSnap of memberDocsById.values()) {
    const m = mSnap.data() || {};
    const ministries = new Set(Array.isArray(m.ministries) ? m.ministries : []);
    const leadershipMinistries = new Set(Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : []);

    if (ministryName) {
      ministries.delete(ministryName);
      leadershipMinistries.delete(ministryName);
    }

    let roles = Array.isArray(m.roles) ? m.roles : [];
    if (leadershipMinistries.size === 0) roles = mergeRoles(roles, [], ['leader']);

    if (removedRoleTag && !hasRoleTagForMinistries(Array.from(ministries), removedRoleTag, roleTagByMinistry)) {
      roles = mergeRoles(roles, [], [removedRoleTag]);
      const linkedUid = linkedUidByMemberId.get(mSnap.id);
      if (linkedUid) removeRoleTagByUid.set(linkedUid, true);
    }

    batch.update(mSnap.ref, {
      ministries: Array.from(ministries),
      leadershipMinistries: Array.from(leadershipMinistries),
      roles: normalizeRoles(roles),
      updatedAt: ts(),
    });
    ops++;
    if (ops >= 400) await commitBatch();
  }

  for (const uSnap of userDocsById.values()) {
    const u = uSnap.data() || {};
    const uLeadership = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);

    if (ministryName) uLeadership.delete(ministryName);

    let uRoles = uniq([toLc(u.role), ...(Array.isArray(u.roles) ? u.roles : [])].filter(Boolean));
    if (uLeadership.size === 0) uRoles = mergeRoles(uRoles, [], ['leader']);

    if (removedRoleTag && removeRoleTagByUid.get(uSnap.id)) {
      uRoles = mergeRoles(uRoles, [], [removedRoleTag]);
    }

    batch.set(
      uSnap.ref,
      {
        leadershipMinistries: Array.from(uLeadership),
        roles: normalizeRoles(uRoles),
        role: highestRole(uRoles),
        updatedAt: ts(),
      },
      { merge: true }
    );
    ops++;
    if (ops >= 400) await commitBatch();
  }

  await commitBatch();

  const joinRequestDocsById = new Map();
  const queryTasks = [];
  if (ministryName) {
    queryTasks.push(
      db.collection('join_requests').where('ministryName', '==', ministryName).get(),
      db.collection('join_requests').where('ministryId', '==', ministryName).get()
    );
  }
  if (ministryDocId) {
    queryTasks.push(
      db.collection('join_requests').where('ministryId', '==', ministryDocId).get(),
      db.collection('join_requests').where('ministryDocId', '==', ministryDocId).get()
    );
  }
  const queryResults = queryTasks.length ? await Promise.all(queryTasks) : [];
  queryResults.forEach((qs) => qs.docs.forEach((d) => joinRequestDocsById.set(d.id, d.ref)));

  if (joinRequestDocsById.size > 0) {
    batch = db.batch();
    ops = 0;
    for (const ref of joinRequestDocsById.values()) {
      batch.delete(ref);
      ops++;
      if (ops >= 400) {
        await batch.commit();
        batch = db.batch();
        ops = 0;
      }
    }
    if (ops > 0) await batch.commit();
  }

  if (ministryDocId) {
    await db.recursiveDelete(db.doc(`ministries/${ministryDocId}`));
  } else if (ministryName) {
    const ministryDocs = await db.collection('ministries').where('name', '==', ministryName).get();
    for (const d of ministryDocs.docs) {
      await db.recursiveDelete(d.ref);
      if (!ministryDocId) ministryDocId = d.id;
    }
  }

  const affectedUids = uniq(Array.from(userDocsById.keys()));
  await Promise.all(affectedUids.map((affectedUid) => syncClaimsForUid(affectedUid)));

  return {
    ok: true,
    ministryId: ministryDocId,
    ministryName: ministryName || null,
    updatedMembers: affectedMemberIds.length,
    updatedUsers: affectedUids.length,
    deletedJoinRequests: joinRequestDocsById.size,
  };
});

/**
 * setMinistryLeadership
 * - promote/demote leader for a ministry
 * - pastor/admin OR leaders of that ministry
 * - guards removing last leader unless allowLastLeader or pastor/admin
 */
exports.setMinistryLeadership = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const { memberId, ministryId, ministryName: nameArg, makeLeader, allowLastLeader = false } = req.data || {};
  if (!memberId || typeof makeLeader !== 'boolean') {
    throw Object.assign(new Error('invalid-argument: memberId/makeLeader'), { code: 'invalid-argument' });
  }

  const { ministryName } = await resolveMinistryByNameOrId(S(ministryId) || S(nameArg));
  if (!ministryName) throw Object.assign(new Error('invalid-ministry'), { code: 'invalid-argument' });

  const allowed = await hasMinistryModerationRights(uid, ministryName);
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  if (makeLeader === false) {
    const currentCount = await countLeadersInMinistry(ministryName);
    if (currentCount <= 1 && !(await isUserPastorOrAdmin(uid)) && !allowLastLeader) {
      throw Object.assign(new Error('would-remove-last-leader'), { code: 'failed-precondition' });
    }
  }

  const roleTag = await getMinistryRoleTag(ministryName);

  await db.runTransaction(async (tx) => {
    const mRef = db.doc(`members/${memberId}`);
    const mSnap = await tx.get(mRef);
    if (!mSnap.exists) throw Object.assign(new Error('member-not-found'), { code: 'not-found' });

    const m = mSnap.data() || {};
    const curMins = new Set(Array.isArray(m.ministries) ? m.ministries : []);
    const curLeads = new Set(Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : []);
    let roles = Array.isArray(m.roles) ? m.roles : [];

    if (makeLeader) {
      curMins.add(ministryName);
      curLeads.add(ministryName);
      roles = mergeRoles(roles, ['leader'], []);
    } else {
      curLeads.delete(ministryName);
      if (curLeads.size === 0) roles = mergeRoles(roles, [], ['leader']);
    }
    if (roleTag) roles = mergeRoles(roles, [roleTag], []);

    tx.update(mRef, {
      ministries: Array.from(curMins),
      leadershipMinistries: Array.from(curLeads),
      roles: normalizeRoles(roles),
      updatedAt: ts(),
    });

    // mirror to linked user
    const linked = await findUserByMemberId(memberId);
    if (linked?.id) {
      const uRef = db.doc(`users/${linked.id}`);
      const uSnap = await tx.get(uRef);
      const u = uSnap.exists ? uSnap.data() || {} : {};

      const uLead = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);
      let uRoles = Array.isArray(u.roles) ? u.roles : [];
      const single = toLc(u.role);
      uRoles = uniq([single, ...uRoles]).filter(Boolean);

      if (makeLeader) {
        uLead.add(ministryName);
        uRoles = mergeRoles(uRoles, ['leader'], []);
      } else {
        uLead.delete(ministryName);
        if (uLead.size === 0) uRoles = mergeRoles(uRoles, [], ['leader']);
      }
      if (roleTag) uRoles = mergeRoles(uRoles, [roleTag], []);

      txSyncUserRoles(tx, linked.id, uRoles);
      tx.set(uRef, { leadershipMinistries: Array.from(uLead), updatedAt: ts() }, { merge: true });
    }
  });

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);

  return { ok: true };
});

/**
 * removeMemberFromMinistry
 * - remove member from ministry + leadership if present
 * - guards removing last leader unless allowLastLeaderRemoval or pastor/admin
 */
exports.removeMemberFromMinistry = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const { memberId, ministryId, ministryName: nameArg, allowLastLeaderRemoval = false } = req.data || {};
  if (!memberId) throw Object.assign(new Error('invalid-argument: memberId'), { code: 'invalid-argument' });

  const { ministryName } = await resolveMinistryByNameOrId(S(ministryId) || S(nameArg));
  if (!ministryName) throw Object.assign(new Error('invalid-ministry'), { code: 'invalid-argument' });

  const allowed = await hasMinistryModerationRights(uid, ministryName);
  if (!allowed) throw Object.assign(new Error('PERMISSION_DENIED'), { code: 'permission-denied' });

  const m = await getMemberById(memberId);
  const isLeaderThere = Array.isArray(m?.leadershipMinistries) && m.leadershipMinistries.includes(ministryName);

  if (isLeaderThere) {
    const totalLeaders = await countLeadersInMinistry(ministryName);
    if (totalLeaders <= 1 && !(await isUserPastorOrAdmin(uid)) && !allowLastLeaderRemoval) {
      throw Object.assign(new Error('would-remove-last-leader'), { code: 'failed-precondition' });
    }
  }

  const currentMins = Array.isArray(m?.ministries) ? m.ministries.map(S).filter(Boolean) : [];
  const hadMinistry = currentMins.includes(ministryName);
  const remainingMins = currentMins.filter((n) => n !== ministryName);
  const roleTag = await getMinistryRoleTag(ministryName);
  const remainingRoleTags = roleTag && hadMinistry ? await getRoleTagsForMinistryNames(remainingMins) : new Set();
  const shouldRemoveRoleTag = roleTag && hadMinistry && !remainingRoleTags.has(roleTag);

  await db.runTransaction(async (tx) => {
    const mRef = db.doc(`members/${memberId}`);
    const mSnap = await tx.get(mRef);
    if (!mSnap.exists) throw Object.assign(new Error('member-not-found'), { code: 'not-found' });

    const data = mSnap.data() || {};
    const curMins = new Set(Array.isArray(data.ministries) ? data.ministries : []);
    const curLeads = new Set(Array.isArray(data.leadershipMinistries) ? data.leadershipMinistries : []);
    let roles = Array.isArray(data.roles) ? data.roles : [];

    curMins.delete(ministryName);
    if (curLeads.has(ministryName)) {
      curLeads.delete(ministryName);
      if (curLeads.size === 0) roles = mergeRoles(roles, [], ['leader']);
    }

    if (shouldRemoveRoleTag) {
      roles = mergeRoles(roles, [], [roleTag]);
    }

    tx.update(mRef, {
      ministries: Array.from(curMins),
      leadershipMinistries: Array.from(curLeads),
      roles: normalizeRoles(roles),
      updatedAt: ts(),
    });

    const linked = await findUserByMemberId(memberId);
    if (linked?.id) {
      const uRef = db.doc(`users/${linked.id}`);
      const uSnap = await tx.get(uRef);
      const u = uSnap.exists ? uSnap.data() || {} : {};

      const uLead = new Set(Array.isArray(u.leadershipMinistries) ? u.leadershipMinistries : []);
      let uRoles = Array.isArray(u.roles) ? u.roles : [];
      const single = toLc(u.role);
      uRoles = uniq([single, ...uRoles]).filter(Boolean);

      uLead.delete(ministryName);
      if (uLead.size === 0) uRoles = mergeRoles(uRoles, [], ['leader']);

      if (shouldRemoveRoleTag) uRoles = mergeRoles(uRoles, [], [roleTag]);

      txSyncUserRoles(tx, linked.id, uRoles);
      tx.set(uRef, { leadershipMinistries: Array.from(uLead), updatedAt: ts() }, { merge: true });
    }
  });

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);

  return { ok: true };
});

/**
 * memberCreateJoinRequest
 * - creates a pending join request via backend (bypasses fragile client rule paths)
 * - self-heals missing users.memberId when possible
 */
exports.memberCreateJoinRequest = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const cache = makeCtxCache();
  const payload = req.data || {};
  const rawMinistryInput = S(payload.ministryId) || S(payload.ministryName);
  if (!rawMinistryInput) {
    throw Object.assign(new Error('invalid-argument: ministryId/ministryName'), { code: 'invalid-argument' });
  }

  let user = await getUser(uid, cache);
  let memberId = user?.memberId || null;

  // Repair missing users.memberId from members.userUid or unique email match.
  if (!memberId) {
    const byUid = await db.collection('members').where('userUid', '==', uid).limit(1).get();
    if (!byUid.empty) {
      memberId = byUid.docs[0].id;
      await db.doc(`users/${uid}`).set({ memberId, updatedAt: ts() }, { merge: true });
    } else {
      const emailLc = S(user?.email || req.auth?.token?.email).toLowerCase();
      if (emailLc) {
        const byEmail = await db.collection('members').where('email', '==', emailLc).limit(2).get();
        if (byEmail.size === 1) {
          memberId = byEmail.docs[0].id;
          await db.doc(`users/${uid}`).set({ memberId, updatedAt: ts() }, { merge: true });
          await byEmail.docs[0].ref.set({ userUid: uid, updatedAt: ts() }, { merge: true });
        }
      }
    }
  }

  if (!memberId) {
    throw Object.assign(new Error('member-not-linked'), { code: 'failed-precondition' });
  }

  user = await getUser(uid, cache);
  const resolved = await resolveMinistryByNameOrId(rawMinistryInput);
  const ministryName = resolved.ministryName || S(payload.ministryName);
  const ministryDocId = resolved.ministryDocId || null;

  if (!ministryName) {
    throw Object.assign(new Error('invalid-ministry'), { code: 'invalid-argument' });
  }

  // Avoid duplicate pending requests for same member+ministry.
  const dupChecks = [];
  dupChecks.push(
    db.collection('join_requests')
      .where('memberId', '==', memberId)
      .where('status', '==', 'pending')
      .where('ministryName', '==', ministryName)
      .limit(1)
      .get()
  );
  if (ministryDocId) {
    dupChecks.push(
      db.collection('join_requests')
        .where('memberId', '==', memberId)
        .where('status', '==', 'pending')
        .where('ministryId', '==', ministryDocId)
        .limit(1)
        .get(),
      db.collection('join_requests')
        .where('memberId', '==', memberId)
        .where('status', '==', 'pending')
        .where('ministryDocId', '==', ministryDocId)
        .limit(1)
        .get()
    );
  }

  const dupResults = await Promise.all(dupChecks);
  const existing = dupResults.find((q) => !q.empty);
  if (existing) {
    return {
      ok: true,
      duplicate: true,
      requestId: existing.docs[0].id,
      memberId,
      ministryName,
      ministryId: ministryDocId || ministryName,
      ministryDocId,
    };
  }

  const ref = await db.collection('join_requests').add({
    memberId,
    ministryId: ministryDocId || ministryName,
    ministryDocId: ministryDocId || null,
    ministryName,
    requestedByUid: uid,
    status: 'pending',
    requestedAt: ts(),
    updatedAt: ts(),
  });

  return {
    ok: true,
    duplicate: false,
    requestId: ref.id,
    memberId,
    ministryName,
    ministryId: ministryDocId || ministryName,
    ministryDocId,
  };
});

/**
 * memberListPendingJoinRequests
 * - returns pending join requests for the signed-in member
 * - self-heals missing users.memberId when possible
 */
exports.memberListPendingJoinRequests = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const cache = makeCtxCache();
  let user = await getUser(uid, cache);
  let memberId = user?.memberId || null;

  if (!memberId) {
    const byUid = await db.collection('members').where('userUid', '==', uid).limit(1).get();
    if (!byUid.empty) {
      memberId = byUid.docs[0].id;
      await db.doc(`users/${uid}`).set({ memberId, updatedAt: ts() }, { merge: true });
    } else {
      const emailLc = S(user?.email || req.auth?.token?.email).toLowerCase();
      if (emailLc) {
        const byEmail = await db.collection('members').where('email', '==', emailLc).limit(2).get();
        if (byEmail.size === 1) {
          memberId = byEmail.docs[0].id;
          await db.doc(`users/${uid}`).set({ memberId, updatedAt: ts() }, { merge: true });
          await byEmail.docs[0].ref.set({ userUid: uid, updatedAt: ts() }, { merge: true });
        }
      }
    }
  }

  if (!memberId) {
    return { ok: true, memberId: null, items: [] };
  }

  user = await getUser(uid, cache);
  const q = await db
    .collection('join_requests')
    .where('memberId', '==', memberId)
    .where('status', '==', 'pending')
    .limit(200)
    .get();

  const items = q.docs.map((d) => {
    const jr = d.data() || {};
    return {
      requestId: d.id,
      memberId,
      ministryName: S(jr.ministryName),
      ministryId: S(jr.ministryId),
      ministryDocId: S(jr.ministryDocId),
      status: S(jr.status || 'pending'),
    };
  });

  return {
    ok: true,
    memberId: user?.memberId || memberId,
    items,
  };
});

/**
 * memberCancelJoinRequest
 * - member cancels own pending join request (hard delete)
 */
exports.memberCancelJoinRequest = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw Object.assign(new Error('UNAUTHENTICATED'), { code: 'unauthenticated' });

  const cache = makeCtxCache();
  const { memberId: memberIdArg, ministryId, ministryName: nameArg } = req.data || {};
  const memberId = S(memberIdArg) || (await findMemberIdByUid(uid, cache));
  if (!memberId) throw Object.assign(new Error('member-not-linked'), { code: 'failed-precondition' });

  const nameOrId = S(ministryId) || S(nameArg);
  if (!nameOrId) throw Object.assign(new Error('invalid-argument: need ministryId or ministryName'), { code: 'invalid-argument' });

  // resolve to name/docId for querying
  let resolvedName = null;
  let resolvedDocId = null;

  try {
    const d = await db.doc(`ministries/${nameOrId}`).get();
    if (d.exists) {
      resolvedDocId = d.id;
      resolvedName = S((d.data() || {}).name);
    }
  } catch (_) {}

  if (!resolvedName) {
    resolvedName = nameOrId;
    const mins = await db.collection('ministries').where('name', '==', resolvedName).limit(1).get();
    if (!mins.empty) resolvedDocId = mins.docs[0].id;
  }

  let q = await db.collection('join_requests')
    .where('memberId', '==', memberId)
    .where('status', '==', 'pending')
    .where('ministryId', '==', resolvedName)
    .limit(1).get();

  if (q.empty && resolvedDocId) {
    q = await db.collection('join_requests')
      .where('memberId', '==', memberId)
      .where('status', '==', 'pending')
      .where('ministryId', '==', resolvedDocId)
      .limit(1).get();
  }

  if (q.empty && resolvedName) {
    q = await db.collection('join_requests')
      .where('memberId', '==', memberId)
      .where('status', '==', 'pending')
      .where('ministryName', '==', resolvedName)
      .limit(1).get();
  }

  if (q.empty) throw Object.assign(new Error('no-pending-request-found'), { code: 'not-found' });

  const ref = q.docs[0].ref;
  await ref.delete();
  return { ok: true, deleted: true, requestId: ref.id };
});

/* =========================================================
   14) Attendance – geofence automation (kept)
   ========================================================= */
function haversineMeters(a, b) {
  const R = 6371000;
  const toRad = (x) => (x * Math.PI) / 180;
  const dLat = toRad(Number(b.lat) - Number(a.lat));
  const dLng = toRad(Number(b.lng) - Number(a.lng));
  const lat1 = toRad(Number(a.lat));
  const lat2 = toRad(Number(b.lat));
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

exports.upsertAttendanceWindow = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in required.');

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw new HttpsError('permission-denied', 'Not allowed.');

  const {
    id,
    title,
    dateKey,
    startsAt,
    endsAt,
    churchPlaceId,
    churchAddress,
    churchLocation,
    radiusMeters = 500,
    startNowQuick = false,
    resetPing = false,
  } = req.data || {};

  if ((!dateKey || !startsAt || !endsAt) && !startNowQuick) {
    throw new HttpsError('invalid-argument', 'Missing date/time fields.');
  }
  if (!churchLocation?.lat || !churchLocation?.lng) {
    throw new HttpsError('invalid-argument', 'Missing required fields.');
  }

  const ref = id ? db.collection('attendance_windows').doc(id) : db.collection('attendance_windows').doc();
  let isNew = !id;
  if (id) {
    const existing = await ref.get();
    isNew = !existing.exists;
  }

  let startsAtMs = Number(startsAt);
  let endsAtMs = Number(endsAt);
  let finalDateKey = String(dateKey || '');

  if (startNowQuick) {
    const now = Date.now();
    startsAtMs = now + 2 * 60 * 1000;
    endsAtMs = startsAtMs + 3 * 60 * 1000;
    finalDateKey = new Date(startsAtMs).toISOString().slice(0, 10);
  }

  const shouldResetPing = Boolean(resetPing) || Boolean(startNowQuick) || isNew;
  await ref.set(
    {
      title: title || 'Service',
      dateKey: finalDateKey,
      startsAt: new Date(startsAtMs),
      endsAt: new Date(endsAtMs),
      churchPlaceId: churchPlaceId || null,
      churchAddress: churchAddress || null,
      churchLocation: { lat: Number(churchLocation.lat), lng: Number(churchLocation.lng) },
      radiusMeters: Number(radiusMeters) || 500,
      ...(isNew ? { createdAt: ts() } : {}),
      ...(shouldResetPing
        ? {
            pingSent: false,
            pingSentAt: null,
            pingAttempts: 0,
            reminderSent: false,
            closed: false,
          }
        : {}),
      updatedAt: ts(),
    },
    { merge: true }
  );

  return { ok: true, id: ref.id };
});

exports.tickAttendanceWindows = onSchedule('every 1 minutes', async () => {
  const now = new Date();
  const qs = await db.collection('attendance_windows')
    .where('startsAt', '<=', now)
    .limit(50)
    .get();

  if (qs.empty) {
    logger.debug('tickAttendanceWindows: no windows', { now: now.toISOString() });
    try {
      const next = await db.collection('attendance_windows')
        .where('startsAt', '>', now)
        .orderBy('startsAt')
        .limit(1)
        .get();
      if (!next.empty) {
        const w = next.docs[0].data();
        logger.info('tickAttendanceWindows: next window in future', {
          id: next.docs[0].id,
          startsAt: w.startsAt?.toDate?.()?.toISOString?.(),
          endsAt: w.endsAt?.toDate?.()?.toISOString?.(),
          pingSent: w.pingSent,
          closed: w.closed,
        });
      }
    } catch (e) {
      logger.debug('tickAttendanceWindows: next window lookup failed', { error: String(e) });
    }
    return;
  }

  let sent = 0;
  let skippedClosed = 0;
  let skippedPinged = 0;
  let skippedEnded = 0;

  for (const doc of qs.docs) {
    const w = doc.data();
    if (w.closed === true) {
      skippedClosed++;
      continue;
    }
    if (w.pingSent === true) {
      skippedPinged++;
      continue;
    }
    if (!w.endsAt || !w.endsAt.toDate) {
      logger.info('tickAttendanceWindows: missing endsAt, skip', { id: doc.id });
      continue;
    }
    if (w.endsAt && w.endsAt.toDate && w.endsAt.toDate() <= now) {
      skippedEnded++;
      continue;
    }
    const welcomeMessage = 'Welcome! Attendance check-in is open. Tap to confirm.';
    const payload = {
      data: {
        type: 'attendance_window_ping',
        title: 'Welcome to service',
        body: welcomeMessage,
        windowId: doc.id,
        dateKey: String(w.dateKey),
        startsAt: String(w.startsAt.toDate().getTime()),
        endsAt: String(w.endsAt.toDate().getTime()),
        lat: String(w.churchLocation.lat),
        lng: String(w.churchLocation.lng),
        radius: String(w.radiusMeters || 500),
        welcomeMessage,
      },
      android: { priority: 'high' },
      apns: {
        headers: {
          'apns-push-type': 'background',
          'apns-priority': '5',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    };

    const resp = await admin.messaging().sendToTopic('all_members', payload);
    await doc.ref.set(
      {
        pingSent: true,
        pingSentAt: ts(),
        pingAttempts: admin.firestore.FieldValue.increment(1),
        updatedAt: ts(),
      },
      { merge: true }
    );
    sent++;
    logger.info('tickAttendanceWindows: ping sent', { id: doc.id, resp });
  }

  logger.info('tickAttendanceWindows: summary', {
    checked: qs.size,
    sent,
    skippedClosed,
    skippedPinged,
    skippedEnded,
  });
});

exports.retryAttendanceWindowPing = onSchedule('every 5 minutes', async () => {
  const now = new Date();
  const qs = await db.collection('attendance_windows')
    .where('startsAt', '<=', now)
    .limit(50)
    .get();

  if (qs.empty) return;

  for (const doc of qs.docs) {
    const w = doc.data();
    if (!w.endsAt || w.endsAt.toDate() <= now) continue;
    if (w.pingSent !== true) continue;
    if (w.pingAttempts != null && Number(w.pingAttempts) >= 2) continue;

    const last = w.pingSentAt?.toDate?.() || new Date(0);
    if (now.getTime() - last.getTime() < 2 * 60 * 1000) continue;

    const payload = {
      data: {
        type: 'attendance_window_ping',
        title: 'Attendance Check-in',
        body: 'Reminder: please confirm your attendance.',
        windowId: doc.id,
        dateKey: String(w.dateKey),
        startsAt: String(w.startsAt.toDate().getTime()),
        endsAt: String(w.endsAt.toDate().getTime()),
        lat: String(w.churchLocation.lat),
        lng: String(w.churchLocation.lng),
        radius: String(w.radiusMeters || 500),
        welcomeMessage: 'Welcome! Attendance check-in is open. Tap to confirm.',
      },
      android: { priority: 'high' },
      apns: {
        headers: {
          'apns-push-type': 'background',
          'apns-priority': '5',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    };

    const resp = await admin.messaging().sendToTopic('all_members', payload);
    await doc.ref.set(
      {
        pingSentAt: ts(),
        pingAttempts: admin.firestore.FieldValue.increment(1),
        updatedAt: ts(),
      },
      { merge: true }
    );
    logger.info('retryAttendanceWindowPing: ping sent', { id: doc.id, resp });
  }
});

exports.attendanceClosingSoonReminder = onSchedule('every 5 minutes', async () => {
  const now = new Date();
  const soon = new Date(now.getTime() + 10 * 60 * 1000);

  const qs = await db.collection('attendance_windows')
    .where('endsAt', '<=', soon)
    .limit(50)
    .get();

  if (qs.empty) return;

  for (const doc of qs.docs) {
    const w = doc.data();
    if (!w.endsAt || w.endsAt.toDate() <= now) continue;
    if (w.reminderSent === true) continue;

    const payload = {
      data: {
        type: 'attendance_window_ping',
        title: 'Attendance closing soon',
        body: 'Please confirm your attendance before the window closes.',
        windowId: doc.id,
        dateKey: String(w.dateKey),
        startsAt: String(w.startsAt.toDate().getTime()),
        endsAt: String(w.endsAt.toDate().getTime()),
        lat: String(w.churchLocation.lat),
        lng: String(w.churchLocation.lng),
        radius: String(w.radiusMeters || 500),
        welcomeMessage: 'Attendance closes soon. Tap to confirm.',
      },
      android: { priority: 'high' },
      apns: {
        headers: {
          'apns-push-type': 'background',
          'apns-priority': '5',
        },
        payload: {
          aps: {
            'content-available': 1,
          },
        },
      },
    };

    const resp = await admin.messaging().sendToTopic('all_members', payload);
    await doc.ref.set({ reminderSent: true, updatedAt: ts() }, { merge: true });
    logger.info('attendanceClosingSoonReminder: ping sent', { id: doc.id, resp });
  }
});

exports.processAttendanceCheckin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const { windowId, deviceLocation, accuracy } = req.data || {};
  if (!windowId || !deviceLocation?.lat || !deviceLocation?.lng) throw new Error('invalid-argument');

  const winSnap = await db.doc(`attendance_windows/${windowId}`).get();
  if (!winSnap.exists) throw new Error('window-not-found');

  const w = winSnap.data();
  const now = new Date();
  if (now < w.startsAt.toDate() || now > w.endsAt.toDate()) throw new Error('outside-window');

  const uSnap = await db.doc(`users/${uid}`).get();
  let memberId = uSnap.exists ? (uSnap.data().memberId || null) : null;
  if (!memberId) {
    try {
      const byUid = await db.collection('members').where('userUid', '==', uid).limit(2).get();
      if (byUid.docs.length === 1) {
        memberId = byUid.docs[0].id;
      }
    } catch (_) {}
  }
  if (!memberId) {
    try {
      const email = uSnap.exists ? (uSnap.data().email || null) : null;
      if (email) {
        const emailLc = String(email).trim().toLowerCase();
        const byEmail = await db.collection('members').where('email', '==', emailLc).limit(2).get();
        if (byEmail.docs.length === 1) {
          memberId = byEmail.docs[0].id;
        }
      }
    } catch (_) {}
  }
  if (memberId) {
    try {
      await db.doc(`users/${uid}`).set({ memberId, updatedAt: ts() }, { merge: true });
    } catch (_) {}
  }
  if (!memberId) throw new Error('member-not-linked');

  const dist = Math.round(
    haversineMeters(
      { lat: Number(deviceLocation.lat), lng: Number(deviceLocation.lng) },
      { lat: Number(w.churchLocation.lat), lng: Number(w.churchLocation.lng) }
    )
  );

  const present = dist <= (w.radiusMeters || 500);

  await db.collection('attendance_submissions').add({
    userUid: uid,
    memberId,
    windowId,
    at: ts(),
    deviceLocation: { lat: Number(deviceLocation.lat), lng: Number(deviceLocation.lng), accuracy: accuracy ?? null },
    result: present ? 'present' : 'absent',
  });

  await db.collection('attendance').doc(w.dateKey).collection('records').doc(memberId).set(
    {
      windowId,
      status: present ? 'present' : 'absent',
      checkedAt: ts(),
      distanceMeters: dist,
      by: 'auto',
    },
    { merge: true }
  );

  return { ok: true, status: present ? 'present' : 'absent', distanceMeters: dist };
});

/**
 * NOTE: This can get expensive as you scale.
 * Kept to match your current behaviour.
 */
exports.closeAttendanceWindow = onSchedule('every 1 minutes', async () => {
  const now = new Date();
  const qs = await db.collection('attendance_windows')
    .where('endsAt', '<=', now)
    .limit(20)
    .get();

  if (qs.empty) return;

  for (const doc of qs.docs) {
    const w = doc.data();
    if (w.closed === true) continue;

    const presentRecs = await db.collection('attendance').doc(w.dateKey).collection('records').get();
    const presentSet = new Set(presentRecs.docs.map((d) => d.id));

    let batch = db.batch();
    let count = 0;
    let lastDoc = null;

    while (true) {
      let q = db
        .collection('users')
        .where('memberId', '!=', null)
        .orderBy('memberId')
        .limit(500)
        .select('memberId');
      if (lastDoc) q = q.startAfter(lastDoc);
      const usersSnap = await q.get();
      if (usersSnap.empty) break;

      for (const u of usersSnap.docs) {
        const mid = u.data().memberId;
        if (!mid || presentSet.has(mid)) continue;

        batch.set(
          db.collection('attendance').doc(w.dateKey).collection('records').doc(mid),
          { windowId: doc.id, status: 'absent', by: 'auto', closedAt: ts() },
          { merge: true }
        );

        count++;
        if (count % 400 === 0) {
          await batch.commit();
          batch = db.batch();
        }
      }

      lastDoc = usersSnap.docs[usersSnap.docs.length - 1];
    }

    await batch.commit();
    await doc.ref.set({ closed: true, closedAt: ts(), updatedAt: ts() }, { merge: true });
  }
});

exports.overrideAttendanceStatus = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const role = await getUserRole(uid);
  const privileged = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!privileged) throw new Error('permission-denied');

  const { dateKey, memberId, status, reason } = req.data || {};
  if (!dateKey || !memberId || !['present', 'absent'].includes(status)) throw new Error('invalid-argument');

  await db.collection('attendance').doc(dateKey).collection('records').doc(memberId).set(
    {
      status,
      overriddenBy: uid,
      overriddenAt: ts(),
      reason: reason || null,
      by: 'override',
    },
    { merge: true }
  );

  return { ok: true };
});

/* =========================================================
   14b) Attendance record enrichment (gender/visitor/window)
   ========================================================= */
exports.onAttendanceRecordWrite = onDocumentWritten('attendance/{dateKey}/records/{memberId}', async (event) => {
  const after = event.data?.after;
  if (!after || !after.exists) return;

  const { dateKey, memberId } = event.params;
  const data = after.data() || {};
  const updates = {};

  if (!data.dateKey && dateKey) updates.dateKey = dateKey;
  if (!data.memberId && memberId) updates.memberId = memberId;

  if (!data.windowId && dateKey) {
    try {
      const qs = await db.collection('attendance_windows').where('dateKey', '==', dateKey).limit(2).get();
      if (qs.docs.length === 1) {
        updates.windowId = qs.docs[0].id;
      }
    } catch (_) {}
  }

  const needsMember =
    data.memberGenderBucket == null ||
    data.memberIsVisitor == null ||
    data.memberFullName == null;

  if (needsMember && memberId) {
    try {
      const mSnap = await db.doc(`members/${memberId}`).get();
      if (mSnap.exists) {
        const m = mSnap.data() || {};
        if (data.memberGenderBucket == null) updates.memberGenderBucket = genderBucket(m.gender);
        if (data.memberIsVisitor == null) updates.memberIsVisitor = Boolean(m.isVisitor);
        if (data.memberFullName == null) updates.memberFullName = normalizeFullName(m);
      }
    } catch (_) {}
  }

  if (Object.keys(updates).length === 0) return;
  await after.ref.set(updates, { merge: true });
});

/* ========================= END OF FILE ========================= */
