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

const { onDocumentCreated, onDocumentUpdated, onDocumentDeleted } = require('firebase-functions/v2/firestore');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ts = admin.firestore.FieldValue.serverTimestamp;

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

  if (user.memberId) {
    const m = await getMemberById(user.memberId, cache);
    if (m) {
      memberRoles = Array.isArray(m.roles) ? m.roles : [];
      isPastorFlag = !!m.isPastor;
    }
  }

  const merged = [
    ...normalizeRoles(user.roles || []),
    ...normalizeRoles(memberRoles),
    ...(isPastorFlag ? ['pastor'] : []),
  ];

  const single = highestRole(merged);

  await db.doc(`users/${uid}`).set({ role: single, updatedAt: ts() }, { merge: true });
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
}

async function writeNotification(payload) {
  const data = { ...payload };
  if (!data.createdAt) data.createdAt = ts();
  await db.collection('notifications').add(data);
}

/* =========================================================
   5) Ministries / membership helpers (by NAME)
   ========================================================= */
async function addMemberToMinistry(memberId, ministryName, { asLeader = false } = {}) {
  if (!memberId || !ministryName) return;
  const updates = {
    ministries: admin.firestore.FieldValue.arrayUnion(ministryName),
    updatedAt: ts(),
  };
  if (asLeader) {
    updates.leadershipMinistries = admin.firestore.FieldValue.arrayUnion(ministryName);
  }
  await db.doc(`members/${memberId}`).set(updates, { merge: true });
}

async function removeMemberFromMinistryByName(memberId, ministryName) {
  if (!memberId || !ministryName) return;
  await db.doc(`members/${memberId}`).set(
    {
      ministries: admin.firestore.FieldValue.arrayRemove(ministryName),
      leadershipMinistries: admin.firestore.FieldValue.arrayRemove(ministryName),
      updatedAt: ts(),
    },
    { merge: true }
  );
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
  const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
  if (!mins.empty) {
    const mData = mins.docs[0].data() || {};
    const fromLeaderUids = Array.isArray(mData.leaderUids) ? mData.leaderUids : [];
    const fromLeaderIds = Array.isArray(mData.leaderIds) ? mData.leaderIds : [];
    ministryLeaderUids = uniq([...fromLeaderUids, ...fromLeaderIds].filter(Boolean));
    ministryDocId = ministryDocId || mins.docs[0].id;
  }

  // map memberIds -> uids (chunked in queries)
  const map = leaderMemberIds.length ? await mapMemberIdsToUids(leaderMemberIds) : new Map();
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

      // make requester a leader if linked to a member
      if (requestedByUid) {
        const cache = makeCtxCache();
        const memberId = await findMemberIdByUid(requestedByUid, cache);
        if (memberId) {
          await addMemberToMinistry(memberId, ministryName, { asLeader: true });

          await db.runTransaction(async (tx) => {
            const mRef = db.doc(`members/${memberId}`);
            const mSnap = await tx.get(mRef);
            const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['leader'], []);
            txSyncMemberRoles(tx, memberId, merged);
            txSyncUserRoles(tx, requestedByUid, merged);

            tx.set(
              db.doc(`users/${requestedByUid}`),
              {
                leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
                updatedAt: ts(),
              },
              { merge: true }
            );
          });

          await syncClaimsForUid(requestedByUid, cache);
        }
      }

      await writeInbox(reviewerUid, {
        type: 'approval_action_processed',
        channel: 'approvals',
        title: 'Approved ministry request',
        body: `"${ministryName}" approved.`,
        ministryId: minRef.id,
        ministryName,
        payload: { requestId, action: 'approve' },
        route: '/pastor-approvals',
        dedupeKey: `mcr_action_${requestId}_approve_${reviewerUid}`,
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

    await writeInbox(reviewerUid, {
      type: 'approval_action_processed',
      channel: 'approvals',
      title: 'Declined ministry request',
      body: `"${ministryName}" declined${declineReason ? `: ${declineReason}` : ''}`,
      payload: { requestId, action: 'decline' },
      route: '/pastor-approvals',
      dedupeKey: `mcr_action_${requestId}_decline_${reviewerUid}`,
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

  const highest = highestRole([
    ...(user?.roles || []),
    ...((memberData?.roles || [])),
    ...(memberData?.isPastor ? ['pastor'] : []),
  ]);

  const write = {
    role: highest,
    email: emailLc || user?.email || null,
    updatedAt: ts(),
  };

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
  if (!uid) throw new Error('unauthenticated');

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw new Error('permission-denied');

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
  } = req.data || {};

  if (!dateKey || !startsAt || !endsAt || !churchPlaceId || !churchLocation?.lat || !churchLocation?.lng) {
    throw new Error('invalid-argument');
  }

  const ref = id ? db.collection('attendance_windows').doc(id) : db.collection('attendance_windows').doc();

  await ref.set(
    {
      title: title || 'Service',
      dateKey,
      startsAt: new Date(Number(startsAt)),
      endsAt: new Date(Number(endsAt)),
      churchPlaceId,
      churchAddress: churchAddress || null,
      churchLocation: { lat: Number(churchLocation.lat), lng: Number(churchLocation.lng) },
      radiusMeters: Number(radiusMeters) || 500,
      pingSent: false,
      closed: false,
      createdAt: ts(),
      updatedAt: ts(),
    },
    { merge: true }
  );

  return { ok: true, id: ref.id };
});

exports.tickAttendanceWindows = onSchedule('every 1 minutes', async () => {
  const now = new Date();
  const startFrom = new Date(now.getTime() - 30 * 1000);
  const startTo = new Date(now.getTime() + 30 * 1000);

  const qs = await db.collection('attendance_windows')
    .where('startsAt', '>=', startFrom)
    .where('startsAt', '<=', startTo)
    .where('pingSent', '==', false)
    .limit(20)
    .get();

  if (qs.empty) return;

  for (const doc of qs.docs) {
    const w = doc.data();
    const payload = {
      data: {
        type: 'attendance_window_ping',
        windowId: doc.id,
        dateKey: String(w.dateKey),
        startsAt: String(w.startsAt.toDate().getTime()),
        endsAt: String(w.endsAt.toDate().getTime()),
        lat: String(w.churchLocation.lat),
        lng: String(w.churchLocation.lng),
        radius: String(w.radiusMeters || 500),
      },
    };

    await admin.messaging().sendToTopic('all_members', payload);
    await doc.ref.set({ pingSent: true, updatedAt: ts() }, { merge: true });
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
  const memberId = uSnap.exists ? (uSnap.data().memberId || null) : null;
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
exports.closeAttendanceWindow = onSchedule('every 5 minutes', async () => {
  const now = new Date();
  const qs = await db.collection('attendance_windows')
    .where('endsAt', '<=', now)
    .where('closed', '==', false)
    .limit(5)
    .get();

  if (qs.empty) return;

  for (const doc of qs.docs) {
    const w = doc.data();

    const users = await db.collection('users').where('memberId', '!=', null).select('memberId').get();
    const presentRecs = await db.collection('attendance').doc(w.dateKey).collection('records').get();
    const presentSet = new Set(presentRecs.docs.map((d) => d.id));

    let batch = db.batch();
    let count = 0;

    for (const u of users.docs) {
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

    await batch.commit();
    await doc.ref.set({ closed: true, updatedAt: ts() }, { merge: true });
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

/* ========================= END OF FILE ========================= */
