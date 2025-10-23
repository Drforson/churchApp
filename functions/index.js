/* functions/index.js */
const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
} = require('firebase-functions/v2/firestore');
const { onCall } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ts = admin.firestore.FieldValue.serverTimestamp;

setGlobalOptions({ region: 'europe-west2', memory: '256MiB', concurrency: 16 });

/* =========================
   Role precedence & helpers
   ========================= */
const ROLE_ORDER_ASC = ['member','usher','leader','pastor','admin']; // ascending
const toLc = (s) => String(s ?? '').toLowerCase().trim();
const S = (v) => (v ?? '').toString().trim();
const uniq = (arr) => Array.from(new Set(arr));
const asArray = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);

/** Only roles your app supports (extend if you add more) */
const ALLOWED_ROLES = ['member','usher','leader','pastor','admin','media'];

/** Normalize arbitrary input to a clean, deduped, lowercase roles array (filtered to allowed). */
function normalizeRoles(input) {
  const norm = uniq(asArray(input).map(toLc).filter(Boolean));
  // keep 'member' implicitly — we only store granted roles above 'member'
  return norm.filter((r) => ALLOWED_ROLES.includes(r) && r !== 'member');
}

/** Highest precedence role from a list (admin > pastor > leader > usher > member). */
function highestRole(rolesArr) {
  const set = new Set(normalizeRoles(rolesArr));
  for (let i = ROLE_ORDER_ASC.length - 1; i >= 0; i--) {
    if (set.has(ROLE_ORDER_ASC[i])) return ROLE_ORDER_ASC[i];
  }
  return 'member';
}

/** Merge current roles with adds/removes. */
function mergeRoles(current, add = [], remove = []) {
  const cur = new Set(normalizeRoles(current));
  for (const a of normalizeRoles(add)) cur.add(a);
  for (const r of normalizeRoles(remove)) cur.delete(r);
  return Array.from(cur);
}

/* =========================
   User/Member fetch helpers
   ========================= */
async function getUser(uid) {
  try {
    if (!uid) return null;
    const snap = await db.doc(`users/${uid}`).get();
    return snap.exists ? { id: snap.id, ...snap.data() } : null;
  } catch (e) {
    logger.error('getUser failed', { uid, error: e });
    return null;
  }
}

async function getUserRole(uid) {
  const u = await getUser(uid);
  if (!u) return 'member';
  if (typeof u.role === 'string' && u.role) return toLc(u.role);
  // fallback to legacy users.roles
  return highestRole(u.roles || []);
}

async function getUserMemberId(uid) {
  const u = await getUser(uid);
  return u?.memberId || null;
}

async function getMemberById(memberId) {
  if (!memberId) return null;
  const m = await db.doc(`members/${memberId}`).get();
  return m.exists ? { id: m.id, ...m.data() } : null;
}

/** Find the user linked to the given memberId (users.memberId == memberId). */
async function findUserByMemberId(memberId) {
  const qs = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
  if (qs.empty) return null;
  const d = qs.docs[0];
  return { id: d.id, ...d.data() };
}

/** Find memberId linked to uid (users.memberId). */
async function findMemberIdByUid(uid) {
  const u = await getUser(uid);
  return u?.memberId || null;
}

/** List uids by current user.role and legacy users.roles (array-contains). */
async function listUidsByRole(roleLc) {
  const set = new Set();
  const q1 = await db.collection('users').where('role', '==', roleLc).get();
  q1.docs.forEach((d) => set.add(d.id));
  const variants = [roleLc, roleLc.toUpperCase(), roleLc[0].toUpperCase() + roleLc.slice(1)];
  const legacyQs = await Promise.all(
    variants.map((r) => db.collection('users').where('roles', 'array-contains', r).get())
  );
  legacyQs.forEach((qs) => qs.docs.forEach((d) => set.add(d.id)));
  return Array.from(set);
}

async function uidsFromMemberIds(memberIds) {
  const out = new Set();
  for (let i = 0; i < memberIds.length; i += 10) {
    const chunk = memberIds.slice(i, i + 10);
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
  {
    const qs = await db.collection('members').where('leadershipMinistries', '!=', null).limit(500).get();
    qs.docs.forEach((d) => {
      const lm = d.data().leadershipMinistries || [];
      if (Array.isArray(lm) && lm.some((s) => String(s).toLowerCase().includes('pastor'))) {
        out.add(d.id);
      }
    });
  }
  return Array.from(out);
}

async function listPastorUids() {
  const fromUsers = await listUidsByRole('pastor');
  const candidateMemberIds = await listMemberIdsByPastorOrAdmin();
  const pastorMemberIds = new Set();
  for (const mid of candidateMemberIds) {
    const snap = await db.doc(`members/${mid}`).get();
    if (!snap.exists) continue;
    const m = snap.data() || {};
    const roles = Array.isArray(m.roles) ? m.roles.map(toLc) : [];
    const isPastor = m.isPastor === true || roles.includes('pastor');
    const lead = Array.isArray(m.leadershipMinistries) ? m.leadershipMinistries : [];
    const looksPastor = isPastor || lead.some((s) => String(s).toLowerCase().includes('pastor'));
    if (looksPastor) pastorMemberIds.add(mid);
  }
  const fromMembers = pastorMemberIds.size ? await uidsFromMemberIds(Array.from(pastorMemberIds)) : [];
  return Array.from(new Set([...fromUsers, ...fromMembers]));
}

async function listPastorAndAdminUids() {
  const [uPastors, uAdmins, memberIds] = await Promise.all([
    listUidsByRole('pastor'),
    listUidsByRole('admin'),
    listMemberIdsByPastorOrAdmin(),
  ]);
  const uidsFromMembers = memberIds.length ? await uidsFromMemberIds(memberIds) : [];
  const set = new Set([...uPastors, ...uAdmins, ...uidsFromMembers]);
  return Array.from(set);
}

async function isUserPastorOrAdmin(uid) {
  const role = await getUserRole(uid);
  if (role === 'pastor' || role === 'admin') return true;

  try {
    const rec = await admin.auth().getUser(uid);
    const c = rec.customClaims || {};
    if (c.pastor === true || c.admin === true || c.isPastor === true || c.isAdmin === true) {
      return true;
    }
  } catch (_) {}

  const memberId = await getUserMemberId(uid);
  if (memberId) {
    const memSnap = await db.doc(`members/${memberId}`).get();
    if (memSnap.exists) {
      const mem = memSnap.data() || {};
      const mroles = Array.isArray(mem.roles) ? mem.roles.map(toLc) : [];
      const lead = Array.isArray(mem.leadershipMinistries) ? mem.leadershipMinistries : [];
      if (mroles.includes('admin')) return true;
      if (mem.isPastor === true || mroles.includes('pastor')) return true;
      if (lead.some((s) => String(s).toLowerCase().includes('pastor'))) return true;
    }
  }
  return false;
}

/* =========================
   Claims & role sync helpers
   ========================= */
async function syncClaimsForUid(uid) {
  try {
    const role = await getUserRole(uid);
    const claims = {
      admin: role === 'admin' || undefined,
      isAdmin: role === 'admin' || undefined,
      pastor: role === 'pastor' || undefined,
      isPastor: role === 'pastor' || undefined,
      leader: role === 'leader' || undefined,
      isLeader: role === 'leader' || undefined,
    };
    await admin.auth().setCustomUserClaims(uid, claims);
    logger.info('syncClaimsForUid', { uid, role, claims });
  } catch (e) {
    logger.error('syncClaimsForUid failed', { uid, error: e });
  }
}

/** Recompute users/{uid}.role from linked member (if any) + users.roles fallback. */
async function recomputeAndWriteUserRole(uid) {
  const user = await getUser(uid);
  if (!user) return;

  let memberRoles = [];
  let isPastorFlag = false;

  if (user.memberId) {
    const mSnap = await db.doc(`members/${user.memberId}`).get();
    if (mSnap.exists) {
      const m = mSnap.data() || {};
      memberRoles = Array.isArray(m.roles) ? m.roles : [];
      isPastorFlag = !!m.isPastor;
    }
  }

  const highest = highestRole([...normalizeRoles(user.roles || []), ...normalizeRoles(memberRoles), ...(isPastorFlag ? ['pastor'] : [])]);

  await db.doc(`users/${uid}`).set({ role: highest, updatedAt: ts() }, { merge: true });
  await syncClaimsForUid(uid);
}

/** In-transaction write: keep users.{roles, role} synced */
function txSyncUserRoles(tx, userId, roles) {
  const rolesClean = normalizeRoles(roles);
  const single = highestRole(rolesClean);
  const ref = db.doc(`users/${userId}`);
  tx.set(ref, {
    roles: rolesClean,
    role: single,
    updatedAt: ts(),
  }, { merge: true });
}

/** In-transaction write: keep members.roles updated */
function txSyncMemberRoles(tx, memberId, roles) {
  const rolesClean = normalizeRoles(roles);
  const ref = db.doc(`members/${memberId}`);
  tx.set(ref, { roles: rolesClean, updatedAt: ts() }, { merge: true });
}

/* =========================
   Notifications / Inbox
   ========================= */
async function writeInbox(uid, payload) {
  await db.collection('inbox').doc(uid).set({ lastSeenAt: ts() }, { merge: true });

  const toWrite = { ...payload, read: false, createdAt: ts() };

  if (payload && payload.dedupeKey) {
    const qs = await db
      .collection('inbox').doc(uid).collection('events')
      .where('dedupeKey', '==', payload.dedupeKey)
      .limit(1).get();
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

/* =========================
   Ministries utilities
   ========================= */
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

async function writeLeaderBroadcast({ ministryName, ministryDocId, joinRequestId, requestedByUid, requesterMemberId, type }) {
  await writeNotification({
    type, // 'join_request' | 'join_request_cancelled'
    ministryId: ministryName,         // NAME (aligns with members[].ministries)
    ministryDocId: ministryDocId || null,
    joinRequestId,
    requestedByUid: requestedByUid || null,
    memberId: requesterMemberId || null,
    audience: { leadersOnly: true, adminAlso: true },
  });
}

async function writeDirectToLeaders({ ministryName, ministryDocId, joinRequestId, requestedByUid, requesterMemberId, type }) {
  const leadersSnap = await db
    .collection('members')
    .where('leadershipMinistries', 'array-contains', ministryName)
    .get();

  let ministryLeaderUids = [];
  const mins = await db
    .collection('ministries')
    .where('name', '==', ministryName)
    .limit(1)
    .get();
  if (!mins.empty) {
    const mData = mins.docs[0].data() || {};
    const fromLeaderUids = Array.isArray(mData.leaderUids) ? mData.leaderUids : [];
    const fromLeaderIds  = Array.isArray(mData.leaderIds)  ? mData.leaderIds  : [];
    ministryLeaderUids = uniq([...fromLeaderUids, ...fromLeaderIds].filter(Boolean));
    ministryDocId = ministryDocId || mins.docs[0].id;
  }

  const batch = db.batch();

  // From member leadershipMinistries → map to users
  for (const lm of leadersSnap.docs) {
    const leaderMemberId = lm.id;
    const userQs = await db
      .collection('users')
      .where('memberId', '==', leaderMemberId)
      .limit(1)
      .get();
    if (userQs.empty) continue;

    const leaderUid = userQs.docs[0].id;
    const ref = db.collection('notifications').doc();
    batch.set(ref, {
      type,
      ministryId: ministryName,
      ministryDocId: ministryDocId || null,
      joinRequestId,
      requestedByUid: requestedByUid || null,
      memberId: requesterMemberId || null,
      recipientUid: leaderUid,
      audience: { direct: true, role: 'leader' },
      createdAt: ts(),
    });
  }

  for (const uid of ministryLeaderUids) {
    const ref = db.collection('notifications').doc();
    batch.set(ref, {
      type,
      ministryId: ministryName,
      ministryDocId: ministryDocId || null,
      joinRequestId,
      requestedByUid: requestedByUid || null,
      memberId: requesterMemberId || null,
      recipientUid: uid,
      audience: { direct: true, role: 'leader' },
      createdAt: ts(),
    });
  }

  await batch.commit();
}

async function notifyRequesterResult({ ministryName, ministryDocId, joinRequestId, requesterMemberId, result, moderatorUid }) {
  let recipientUid = null;
  const userQs = await db
    .collection('users')
    .where('memberId', '==', requesterMemberId)
    .limit(1)
    .get();
  if (!userQs.empty) recipientUid = userQs.docs[0].id;

  await writeNotification({
    type: 'join_request_result',
    result, // 'approved' | 'rejected'
    ministryId: ministryName,
    ministryDocId: ministryDocId || null,
    joinRequestId,
    memberId: requesterMemberId,
    recipientUid: recipientUid || null,
    moderatorUid: moderatorUid || null,
  });
}

/* =========================================================
   1) Ministry approval actions (secure)
   ========================================================= */
exports.processMinistryApprovalAction = onDocumentCreated(
  'ministry_approval_actions/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;

    const { decision, requestId, reason, reviewerUid } = doc.data() || {};
    logger.info('processMinistryApprovalAction received', { id: doc.id, decision, requestId, reviewerUid });

    if (!decision || !requestId || !reviewerUid) {
      logger.warn('Invalid payload on approval action', { id: doc.id });
      await doc.ref.update({ status: 'invalid', processed: true, processedAt: new Date() });
      return;
    }

    const allowed = await isUserPastorOrAdmin(reviewerUid);
    if (!allowed) {
      logger.warn('Unauthorized approval action', { reviewerUid });
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

        if (requestedByUid) {
          const memberId = await getUserMemberId(requestedByUid);
          if (memberId) {
            await addMemberToMinistry(memberId, ministryName, { asLeader: true });
            // mirror 'leader' to user + member role arrays
            await db.runTransaction(async (tx) => {
              const mRef = db.doc(`members/${memberId}`);
              const mSnap = await tx.get(mRef);
              const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['leader'], []);
              txSyncMemberRoles(tx, memberId, merged);
              txSyncUserRoles(tx, requestedByUid, merged);
              const uRef = db.doc(`users/${requestedByUid}`);
              tx.set(uRef, {
                leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
                updatedAt: ts(),
              }, { merge: true });
            });
            await syncClaimsForUid(requestedByUid);
          }
        }

        await notifyRequesterResult({
          ministryName,
          ministryDocId: minRef.id,
          joinRequestId: null,
          requesterMemberId: null,
          result: 'approved',
          moderatorUid: reviewerUid,
        });

        await writeInbox(reviewerUid, {
          type: 'approval_action_processed',
          channel: 'approvals',
          title: 'Approved ministry request',
          body: ministryName ? `"${ministryName}" approved.` : 'Ministry request approved.',
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
        ministryName: ministryName || null,
        ministryDocId: null,
        recipientUid: (S(r.requestedByUid) || null) || null,
        reviewerUid: reviewerUid || null,
        reason: declineReason,
        createdAt: ts(),
      });

      await reqRef.delete();

      await writeInbox(reviewerUid, {
        type: 'approval_action_processed',
        channel: 'approvals',
        title: 'Declined ministry request',
        body: ministryName
          ? `"${ministryName}" declined${declineReason ? `: ${declineReason}` : ''}`
          : `Ministry request declined${declineReason ? `: ${declineReason}` : ''}`,
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
  }
);

/* =========================================================
   1b) Direct status flip to "approved" handler
   ========================================================= */
exports.onMinistryRequestApproved = onDocumentUpdated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after  = event.data?.after?.data();
    if (!before || !after) return;

    const prev = toLc(S(before.status || 'pending'));
    const theNext = toLc(S(after.status  || 'pending'));

    if (prev === 'approved' || theNext !== 'approved') return;

    const reqRef = event.data.after.ref;

    if (after.approvedMinistryId) return;

    const ministryName   = S(after.name || after.ministryName);
    const description    = S(after.description);
    const requestedByUid = S(after.requestedByUid);
    const reviewerUid    = S(after.approvedByUid) || 'system';

    if (!ministryName) {
      await reqRef.update({ status: 'error', error: 'missing-ministry-name', updatedAt: ts() });
      return;
    }

    const existing = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
    if (!existing.empty) {
      const minDoc = existing.docs[0];
      await reqRef.update({
        approvedMinistryId: minDoc.id,
        updatedAt: ts(),
      });

      if (requestedByUid) {
        const memberId = await getUserMemberId(requestedByUid);
        if (memberId) {
          await addMemberToMinistry(memberId, ministryName, { asLeader: true });
          await db.runTransaction(async (tx) => {
            const mRef = db.doc(`members/${memberId}`);
            const mSnap = await tx.get(mRef);
            const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['leader'], []);
            txSyncMemberRoles(tx, memberId, merged);
            txSyncUserRoles(tx, requestedByUid, merged);
            const uRef = db.doc(`users/${requestedByUid}`);
            tx.set(uRef, {
              leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
              updatedAt: ts(),
            }, { merge: true });
          });
          await syncClaimsForUid(requestedByUid);
        }
      }
      return;
    }

    const minRef = db.collection('ministries').doc();
    await db.runTransaction(async (txn) => {
      txn.set(minRef, {
        id: minRef.id,
        name: ministryName,
        description,
        approved: true,
        createdAt: ts(),
        createdBy: reviewerUid || 'system',
        leaderUids: requestedByUid ? [requestedByUid] : [],
      });
      txn.update(reqRef, {
        approvedMinistryId: minRef.id,
        updatedAt: ts(),
      });
    });

    if (requestedByUid) {
      const memberId = await getUserMemberId(requestedByUid);
      if (memberId) {
        await addMemberToMinistry(memberId, ministryName, { asLeader: true });
        await db.runTransaction(async (tx) => {
          const mRef = db.doc(`members/${memberId}`);
          const mSnap = await tx.get(mRef);
          const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['leader'], []);
          txSyncMemberRoles(tx, memberId, merged);
          txSyncUserRoles(tx, requestedByUid, merged);
          const uRef = db.doc(`users/${requestedByUid}`);
          tx.set(uRef, {
            leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
            updatedAt: ts(),
          }, { merge: true });
        });
        await syncClaimsForUid(requestedByUid);
      }
    }
  }
);

/* =========================================================
   2) Notify pastors/admins when a ministry creation request is created
   ========================================================= */
exports.onMinistryCreationRequestCreated = onDocumentCreated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const r = snap.data() || {};
    const name = S(r.name || r.ministryName);
    logger.info('ministry_creation_requests CREATED', { id: snap.id, requestedByUid: r.requestedByUid, name });

    const approverUids = await listPastorAndAdminUids();
    if (!approverUids.length) {
      logger.warn('No pastors/admins to notify for new ministry request');
      return;
    }

    await Promise.all(
      approverUids.map((uid) =>
        writeInbox(uid, {
          type: 'ministry_request_created',
          channel: 'approvals',
          title: 'New ministry creation request',
          body: name ? `Ministry: ${name}` : 'A new request was submitted',
          ministryId: null,
          ministryName: name || null,
          payload: { requestId: snap.id, ministryName: name || null },
          route: '/pastor-approvals',
          dedupeKey: `mcr_created_${snap.id}_${uid}`,
        })
      )
    );
  }
);

/* =========================================================
   3) Notify leaders when a join request is created
   ========================================================= */
exports.onJoinRequestCreated = onDocumentCreated(
  'join_requests/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;
    const jr = doc.data() || {};
    const memberId = S(jr.memberId);
    const ministryName = S(jr.ministryId); // NAME (matches members[].ministries)
    const requestedByUid = S(jr.requestedByUid);
    if (!ministryName) return;

    let ministryDocId = null;
    const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
    if (!mins.empty) {
      ministryDocId = mins.docs[0].id;
    }

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
  }
);

/* =========================================================
   4) Join request status changes
   ========================================================= */
exports.onJoinRequestUpdated = onDocumentUpdated(
  'join_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const prev = toLc(S(before.status || 'pending'));
    const theNext = toLc(S(after.status || 'pending'));
    if (prev === theNext) return;

    const memberId = S(after.memberId);
    const ministryName = S(after.ministryId);
    if (!memberId || !ministryName) return;

    let ministryDocId = S(after.ministryDocId) || null;
    if (!ministryDocId) {
      const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
      if (!mins.empty) ministryDocId = mins.docs[0].id;
    }

    const moderatorUid = S(after.moderatorUid) || null;

    if (theNext === 'approved' || theNext === 'rejected') {
      logger.info('join_requests STATUS CHANGE', {
        id: event.params.id, from: prev, to: theNext, memberId, ministryName,
      });

      await notifyRequesterResult({
        ministryName,
        ministryDocId,
        joinRequestId: event.params.id,
        requesterMemberId: memberId,
        result: theNext,
        moderatorUid,
      });
    }

    if (theNext === 'approved') {
      await addMemberToMinistry(memberId, ministryName, { asLeader: false });
    }
  }
);

/* =========================================================
   4b) Notify leaders when a pending join request is deleted (cancelled)
   ========================================================= */
exports.onJoinRequestDeleted = onDocumentDeleted(
  'join_requests/{id}',
  async (event) => {
    const r = event.data?.data() || {};
    const status = toLc(r.status || 'pending');
    if (status !== 'pending') return;

    const ministryName = S(r.ministryId);
    let ministryDocId = S(r.ministryDocId) || null;
    const requesterMemberId = S(r.memberId);
    const requestedByUid = S(r.requestedByUid);
    const joinRequestId = event.params.id;

    if (!ministryName || !requesterMemberId) return;

    if (!ministryDocId) {
      const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
      if (!mins.empty) ministryDocId = mins.docs[0].id;
    }

    logger.info('join_requests CANCELLED', { id: joinRequestId, ministryName, requesterMemberId });

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
  }
);

/* =========================================================
   5) Notify pastors when a prayer request is submitted
   ========================================================= */
exports.onPrayerRequestCreated = onDocumentCreated(
  'prayerRequests/{id}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const r = snap.data() || {};
    const name = S(r.name) || (r.isAnonymous ? 'Anonymous' : '');
    const email = S(r.email);
    const message = S(r.message || r.request);
    const requesterUid = S(r.requestedByUid);
    const channel = 'prayer';

    const pastorUids = await listPastorUids();
    if (!pastorUids.length) {
      logger.warn('No pastors to notify for prayer request');
      return;
    }

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
  }
);

/* =========================================================
   6) CALLABLES — role/claims & admin paths
   ========================================================= */

/** Ensure users/{uid} exists/updated; recompute single role; sync claims. */
exports.ensureUserDoc = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  // Prefer Auth record for canonical email
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
    await ref.set(
      {
        email,
        role: 'member',
        createdAt: ts(),
        updatedAt: ts(),
      },
      { merge: true }
    );
  } else {
    await ref.set({ email, updatedAt: ts() }, { merge: true });
  }

  await recomputeAndWriteUserRole(uid);
  logger.info('ensureUserDoc ok', { uid, email });
  return { ok: true };
});

/** Called after signup + every login (client) to sync role from linked member/email. */
exports.syncUserRoleFromMemberOnLogin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const authUser = await admin.auth().getUser(uid);
  const emailLc = (authUser.email || '').trim().toLowerCase();

  let user = await getUser(uid);
  const now = ts();

  let memberSnap = null;
  if (user?.memberId) {
    const m = await db.doc(`members/${user.memberId}`).get();
    if (m.exists) memberSnap = m;
  }
  if (!memberSnap && emailLc) {
    const q = await db.collection('members').where('email', '==', emailLc).limit(1).get();
    if (!q.empty) memberSnap = q.docs[0];
  }

  const memberData = memberSnap?.data() || null;

  const highest = highestRole([
    ...(user?.roles || []),
    ...((memberData?.roles || [])),
    ...(memberData?.isPastor ? ['pastor'] : []),
  ]);

  const userRef = db.doc(`users/${uid}`);
  const write = {
    role: highest,
    email: emailLc || user?.email || null,
    updatedAt: now,
  };
  if (memberSnap && !user?.memberId) write.memberId = memberSnap.id;

  await userRef.set(write, { merge: true });
  await syncClaimsForUid(uid);

  return { ok: true, role: highest, linkedMemberId: write.memberId || user?.memberId || null };
});

/** Toggle 'pastor' for a member; mirrors to linked user (roles[] and single role). */
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
    if (linked?.id) {
      txSyncUserRoles(tx, linked.id, merged);
    }
  });

  // sync claims for linked user (if any)
  const linked = await findUserByMemberId(memberId);
  if (linked?.id) await syncClaimsForUid(linked.id);

  return { ok: true };
});

/** Bulk roles add/remove for members; mirrors to linked users (roles[] and single role). */
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
      if (linked?.id) {
        txSyncUserRoles(tx, linked.id, merged);
      }

      updated += 1;
    });

    // claims sync outside the tx
    const linked = await findUserByMemberId(memberId);
    if (linked?.id) await syncClaimsForUid(linked.id);
  }

  return { ok: true, updated };
});

/** Elevate caller to admin; mirrors to member if linked; keeps roles[] and single role in sync. */
exports.promoteMeToAdmin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  // Allow an admin/pastor to self-elevate; adjust if you want stricter policy.
  const caller = await getUser(uid);
  const callerRoles = normalizeRoles(caller?.roles || caller?.role || []);
  const allowed = callerRoles.includes('admin') || callerRoles.includes('pastor');
  if (!allowed) {
    const err = new Error('permission-denied: admin or pastor required');
    err.code = 'permission-denied';
    throw err;
  }

  const memberId = await findMemberIdByUid(uid);
  await db.runTransaction(async (tx) => {
    if (memberId) {
      const mRef = db.doc(`members/${memberId}`);
      const mSnap = await tx.get(mRef);
      const merged = mergeRoles(mSnap.exists ? (mSnap.data().roles || []) : [], ['admin'], []);
      txSyncMemberRoles(tx, memberId, merged);
      txSyncUserRoles(tx, uid, merged);
    } else {
      const mergedUser = mergeRoles(callerRoles, ['admin'], []);
      txSyncUserRoles(tx, uid, mergedUser);
    }
  });

  await syncClaimsForUid(uid);
  return { ok: true };
});

/** Trigger: when a member's roles change, mirror to linked user's roles + single role. */
exports.onMemberRolesChanged = onDocumentUpdated('members/{memberId}', async (event) => {
  const before = event.data?.before?.data() || {};
  const after = event.data?.after?.data() || {};
  const memberId = event.params.memberId;

  const beforeRoles = normalizeRoles(before.roles || []);
  const afterRoles = normalizeRoles(after.roles || []);

  if (beforeRoles.join('|') === afterRoles.join('|')) return;

  const linked = await findUserByMemberId(memberId);
  if (linked?.id) {
    const rolesClean = afterRoles;
    const single = highestRole(rolesClean);
    await db.doc(`users/${linked.id}`).set({
      roles: rolesClean,
      role: single,
      updatedAt: ts(),
    }, { merge: true });
    await syncClaimsForUid(linked.id);
    logger.info(`Synced user ${linked.id} with member ${memberId} roles`, { afterRoles });
  }
});

/* =========================================================
   7) Attendance – geofence-based automation
   ========================================================= */
// Haversine distance (meters)
function haversineMeters(a, b) {
  const R = 6371000; // meters
  const toRad = (x) => (x * Math.PI) / 180;
  const dLat = toRad(Number(b.lat) - Number(a.lat));
  const dLng = toRad(Number(b.lng) - Number(a.lng));
  const lat1 = toRad(Number(a.lat));
  const lat2 = toRad(Number(b.lat));
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Create/Update attendance window (admin/pastor/leader) */
exports.upsertAttendanceWindow = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const role = await getUserRole(uid);
  const allowed = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!allowed) throw new Error('permission-denied');

  const {
    id,                   // optional (update)
    title,
    dateKey,              // 'YYYY-MM-DD'
    startsAt,             // epoch ms (UTC)
    endsAt,               // epoch ms (UTC)
    churchPlaceId,
    churchAddress,
    churchLocation,       // { lat, lng }
    radiusMeters = 500,
  } = req.data || {};

  if (
    !dateKey || !startsAt || !endsAt ||
    !churchPlaceId || !churchLocation?.lat || !churchLocation?.lng
  ) throw new Error('invalid-argument');

  const ref = id
    ? db.collection('attendance_windows').doc(id)
    : db.collection('attendance_windows').doc();

  await ref.set({
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
  }, { merge: true });

  return { ok: true, id: ref.id };
});

/** Scheduler: broadcast a data FCM ping at window start */
exports.tickAttendanceWindows = onSchedule('every 1 minutes', async () => {
  const now = new Date();
  const startFrom = new Date(now.getTime() - 30 * 1000);
  const startTo   = new Date(now.getTime() + 30 * 1000);

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
        endsAt:   String(w.endsAt.toDate().getTime()),
        lat: String(w.churchLocation.lat),
        lng: String(w.churchLocation.lng),
        radius: String(w.radiusMeters || 500),
      }
    };

    await admin.messaging().sendToTopic('all_members', payload);
    await doc.ref.set({ pingSent: true, updatedAt: ts() }, { merge: true });
  }
});

/** Callable: client sends one-shot GPS; server validates + writes authoritative record */
exports.processAttendanceCheckin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const { windowId, deviceLocation, accuracy } = req.data || {};
  if (!windowId || !deviceLocation?.lat || !deviceLocation?.lng)
    throw new Error('invalid-argument');

  const winSnap = await db.doc(`attendance_windows/${windowId}`).get();
  if (!winSnap.exists) throw new Error('window-not-found');
  const w = winSnap.data();

  const now = new Date();
  if (now < w.startsAt.toDate() || now > w.endsAt.toDate())
    throw new Error('outside-window');

  const u = await db.doc(`users/${uid}`).get();
  const memberId = u.exists ? (u.data().memberId || null) : null;
  if (!memberId) throw new Error('member-not-linked');

  const dist = Math.round(haversineMeters(
    { lat: Number(deviceLocation.lat), lng: Number(deviceLocation.lng) },
    { lat: Number(w.churchLocation.lat), lng: Number(w.churchLocation.lng) }
  ));
  const present = dist <= (w.radiusMeters || 500);

  await db.collection('attendance_submissions').add({
    userUid: uid,
    memberId,
    windowId,
    at: ts(),
    deviceLocation: {
      lat: Number(deviceLocation.lat),
      lng: Number(deviceLocation.lng),
      accuracy: accuracy ?? null,
    },
    result: present ? 'present' : 'absent',
  });

  const recRef = db.collection('attendance').doc(w.dateKey)
                   .collection('records').doc(memberId);
  await recRef.set({
    windowId,
    status: present ? 'present' : 'absent',
    checkedAt: ts(),
    distanceMeters: dist,
    by: 'auto'
  }, { merge: true });

  return { ok: true, status: present ? 'present' : 'absent', distanceMeters: dist };
});

/** Finalizer: after window ends, mark everyone else absent */
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

    const users = await db.collection('users')
      .where('memberId', '!=', null)
      .select('memberId').get();

    const presentRecs = await db.collection('attendance').doc(w.dateKey)
      .collection('records').get();
    const presentSet = new Set(presentRecs.docs.map(d => d.id));

    let batch = db.batch();
    let count = 0;

    for (const u of users.docs) {
      const mid = u.data().memberId;
      if (!mid || presentSet.has(mid)) continue;

      const ref = db.collection('attendance').doc(w.dateKey).collection('records').doc(mid);
      batch.set(ref, {
        windowId: doc.id,
        status: 'absent',
        by: 'auto',
        closedAt: ts()
      }, { merge: true });

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

/** Manual override by usher/pastor/leader */
exports.overrideAttendanceStatus = onCall(async (req) => {
  const uid = req.auth?.uid; if (!uid) throw new Error('unauthenticated');

  const role = await getUserRole(uid);
  const privileged = (await isUserPastorOrAdmin(uid)) || role === 'leader';
  if (!privileged) throw new Error('permission-denied');

  const { dateKey, memberId, status, reason } = req.data || {};
  if (!dateKey || !memberId || !['present','absent'].includes(status))
    throw new Error('invalid-argument');

  const ref = db.collection('attendance').doc(dateKey).collection('records').doc(memberId);
  await ref.set({
    status,
    overriddenBy: uid,
    overriddenAt: ts(),
    reason: reason || null,
    by: 'override'
  }, { merge: true });

  return { ok: true };
});
