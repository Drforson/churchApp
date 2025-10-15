/* functions/index.js */
const {
  onDocumentCreated,
  onDocumentUpdated,
  onDocumentDeleted,
} = require('firebase-functions/v2/firestore');
const { onCall } = require('firebase-functions/v2/https');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ts = admin.firestore.FieldValue.serverTimestamp;

setGlobalOptions({ region: 'europe-west2' });

/* ========= Role precedence (single user.role) ========= */
const ROLE_ORDER = ['member', 'usher', 'leader', 'pastor', 'admin']; // ascending
const toRole = (s) => (s ? String(s).toLowerCase().trim() : 'member');

/** Highest by precedence from a user.role + member.roles + isPastor */
function highestRoleFromArrays({ userRole, memberRoles = [], isPastorFlag = false }) {
  const u = toRole(userRole);
  const m = (Array.isArray(memberRoles) ? memberRoles : []).map(toRole);
  if (isPastorFlag && !m.includes('pastor')) m.push('pastor');

  const pool = new Set([u, ...m].filter(Boolean));
  let best = 'member';
  for (const r of ROLE_ORDER) if (pool.has(r)) best = r;
  return best;
}

/* ========= Helpers ========= */
const S = (v) => (v ?? '').toString().trim();
const asArray = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);
const toLc = (s) => String(s).toLowerCase().trim();
const uniq = (arr) => Array.from(new Set(arr));
const normalizeRoles = (input) => {
  const arr = Array.isArray(input)
    ? input
    : typeof input === 'string'
    ? input.split(',')
    : [];
  return uniq(arr.map(toLc).filter(Boolean));
};

async function getUser(uid) {
  try {
    const snap = await db.doc(`users/${uid}`).get();
    return snap.exists ? { id: snap.id, ...snap.data() } : null;
  } catch (e) {
    logger.error('getUser failed', { uid, error: e });
    return null;
  }
}

/** NEW: single-role reader with legacy array fallback */
async function getUserRole(uid) {
  const u = await getUser(uid);
  if (u && typeof u.role === 'string' && u.role) return toRole(u.role);
  const arr = normalizeRoles(u?.roles ?? []);
  if (arr.includes('admin')) return 'admin';
  if (arr.includes('pastor')) return 'pastor';
  if (arr.includes('leader')) return 'leader';
  if (arr.includes('usher')) return 'usher';
  return 'member';
}

/** legacy: array roles reader retained for compatibility paths */
async function getUserRolesLegacy(uid) {
  const u = await getUser(uid);
  return normalizeRoles(u?.roles ?? []);
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

async function getMember(uid) {
  const memberId = await getUserMemberId(uid);
  return memberId ? await getMemberById(memberId) : null;
}

/** UPDATED: list uids by role supports new single user.role and legacy users.roles[] */
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

/* Fallback: discover pastor/admin from members */
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

/* Only pastors (user.role or member signals) */
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

  const mem = await getMember(uid);
  if (mem) {
    const mroles = Array.isArray(mem.roles) ? mem.roles.map(toLc) : [];
    const lead = Array.isArray(mem.leadershipMinistries) ? mem.leadershipMinistries : [];
    if (mroles.includes('admin')) return true;
    if (mem.isPastor === true || mroles.includes('pastor')) return true;
    if (lead.some((s) => String(s).toLowerCase().includes('pastor'))) return true;
  }
  return false;
}

/* NEW: does uid lead ministryName (via user.leadershipMinistries or ministries.leaderUids/leaderIds)? */
async function isUserLeaderOfMinistry(uid, ministryName) {
  if (!uid || !ministryName) return false;

  const user = await getUser(uid);
  const leadsByUser =
    Array.isArray(user?.leadershipMinistries) &&
    user.leadershipMinistries.includes(ministryName);

  let leadsByMinistry = false;
  const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
  if (!mins.empty) {
    const mData = mins.docs[0].data() || {};
    const leaderUids = Array.isArray(mData.leaderUids) ? mData.leaderUids : [];
    const leaderIds  = Array.isArray(mData.leaderIds)  ? mData.leaderIds  : [];
    leadsByMinistry = leaderUids.includes(uid) || leaderIds.includes(uid);
  }
  return leadsByUser || leadsByMinistry;
}

/* UPDATED: sync claims from single user.role */
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

/* Helper: recompute & write user.role from linked member (if any) */
async function recomputeAndWriteUserRole(uid) {
  const user = await getUser(uid);
  if (!user) return;

  let memberSnap = null;
  if (user.memberId) {
    const m = await db.doc(`members/${user.memberId}`).get();
    if (m.exists) memberSnap = m;
  }

  const memberData = memberSnap?.data() || null;
  const highest = highestRoleFromArrays({
    userRole: user.role || 'member',
    memberRoles: memberData?.roles || [],
    isPastorFlag: !!memberData?.isPastor,
  });

  await db.doc(`users/${uid}`).set(
    { role: highest, updatedAt: ts() },
    { merge: true }
  );
  await syncClaimsForUid(uid);
}

/* Update member + linked user (legacy roles arrays still supported) */
async function updateMemberAndLinkedUserRoles(memberId, { add = [], remove = [], setFlags = {} } = {}) {
  const addLc = normalizeRoles(add);
  const remLc = normalizeRoles(remove);

  const memberRef = db.doc(`members/${memberId}`);
  const memberSnap = await memberRef.get();
  if (!memberSnap.exists) throw new Error('member not found');

  const batch = db.batch();
  const memberUpdate = { updatedAt: ts() };
  if (addLc.length) memberUpdate.roles = admin.firestore.FieldValue.arrayUnion(...addLc);
  if (remLc.length) memberUpdate.roles = admin.firestore.FieldValue.arrayRemove(...remLc);
  for (const [k, v] of Object.entries(setFlags)) memberUpdate[k] = v;
  batch.update(memberRef, memberUpdate);

  const usersQ = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
  let uid = null;
  if (!usersQ.empty) {
    uid = usersQ.docs[0].id;
    batch.set(usersQ.docs[0].ref, { updatedAt: ts() }, { merge: true });
  }

  await batch.commit();

  if (uid) await recomputeAndWriteUserRole(uid);
}

/* Inbox writer */
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

/* Notifications collection */
async function writeNotification(payload) {
  const data = { ...payload };
  if (!data.createdAt) data.createdAt = ts();
  await db.collection('notifications').add(data);
}

/* ========= Utility: add a member to a ministry ========= */
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

/* ========= Notifications helpers for leaders (join requests) ========= */
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

/* Read leaders both from members.leadershipMinistries and ministries.leaderUids/leaderIds */
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

/* ========= Join-request requester result ========= */
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

/* ========= Ministry-request requester result ========= */
async function notifyMinistryRequesterResult({ requestId, requesterUid, ministryName, ministryDocId, result, reviewerUid, reason }) {
  if (!requesterUid) return;

  await writeNotification({
    type: 'ministry_request_result',
    result, // 'approved' | 'declined'
    requestId,
    ministryName: ministryName || null,
    ministryDocId: ministryDocId || null,
    recipientUid: requesterUid,
    reviewerUid: reviewerUid || null,
    reason: reason || null,
  });

  await writeInbox(requesterUid, {
    type: result === 'approved' ? 'ministry_request_approved' : 'ministry_request_declined',
    channel: 'approvals',
    title: result === 'approved' ? 'Your ministry was approved' : 'Your ministry was declined',
    body:
      result === 'approved'
        ? (ministryName ? `"${ministryName}" is now live.` : 'Your ministry request is approved.')
        : (ministryName ? `"${ministryName}" was declined${reason ? `: ${reason}` : ''}` : `Your request was declined${reason ? `: ${reason}` : ''}`),
    ministryId: ministryDocId || null,
    ministryName: ministryName || null,
    payload: { requestId, ministryId: ministryDocId || null, ministryName: ministryName || null },
    route: '/pastor-approvals',
    dedupeKey: `min_req_${requestId}_${result}`,
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
            await updateMemberAndLinkedUserRoles(memberId, { add: ['leader'] });
            await db.doc(`users/${requestedByUid}`).set({
              leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
              updatedAt: ts(),
            }, { merge: true });
          }
        }

        await notifyMinistryRequesterResult({
          requestId,
          requesterUid: requestedByUid || null,
          ministryName,
          ministryDocId: minRef.id,
          result: 'approved',
          reviewerUid,
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

      await notifyMinistryRequesterResult({
        requestId,
        requesterUid: requestedByUid || null,
        ministryName,
        ministryDocId: null,
        result: 'declined',
        reviewerUid,
        reason: declineReason,
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
   1b) ALSO handle direct status flip to "approved"
   ========================================================= */
exports.onMinistryRequestApproved = onDocumentUpdated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after  = event.data?.after?.data();
    if (!before || !after) return;

    const prev = String(before.status || 'pending').toLowerCase();
    const next = String(after.status  || 'pending').toLowerCase();

    // Only act on actual transition to approved
    if (prev === 'approved' || next !== 'approved') return;

    const reqRef = event.data.after.ref;

    // If already processed (has approvedMinistryId), do nothing (idempotent)
    if (after.approvedMinistryId) return;

    const ministryName   = (after.name || after.ministryName || '').toString().trim();
    const description    = (after.description || '').toString();
    const requestedByUid = (after.requestedByUid || '').toString().trim();
    const reviewerUid    = (after.approvedByUid || '').toString().trim() || 'system';

    if (!ministryName) {
      await reqRef.update({ status: 'error', error: 'missing-ministry-name', updatedAt: ts() });
      return;
    }

    // Prevent duplicate names: if ministry with this name exists, just bind it to the request
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
          await updateMemberAndLinkedUserRoles(memberId, { add: ['leader'] });
          await db.doc(`users/${requestedByUid}`).set({
            leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
            updatedAt: ts(),
          }, { merge: true });
        }
      }
      return;
    }

    // Create new ministry, link requester as leader (if we can resolve their member)
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
        await updateMemberAndLinkedUserRoles(memberId, { add: ['leader'] });
        await db.doc(`users/${requestedByUid}`).set({
          leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
          updatedAt: ts(),
        }, { merge: true });
      }
    }
  }
);

/* =========================================================
   2) Notify pastors/admins for new ministry creation requests
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
   3) Notify leaders when a join request is created  ➜ /notifications
   ========================================================= */
exports.onJoinRequestCreated = onDocumentCreated(
  'join_requests/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;
    const jr = doc.data() || {};
    const memberId = S(jr.memberId);
    const ministryName = S(jr.ministryId); // NAME matches members[].ministries
    const requestedByUid = S(jr.requestedByUid);
    if (!ministryName) return;

    let ministryDocId = null;
    const mins = await db
      .collection('ministries')
      .where('name', '==', ministryName)
      .limit(1)
      .get();
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
   4) When join request status changes:
      - notify requester
      - if APPROVED: add member to the ministry
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
      const mins = await db
        .collection('ministries')
        .where('name', '==', ministryName)
        .limit(1)
        .get();
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
      const mins = await db
        .collection('ministries')
        .where('name', '==', ministryName)
        .limit(1)
        .get();
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

/** ✅ GUARANTEED FIX: create/update users/{uid} AFTER login via Admin SDK (bypasses rules) */
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
        role: 'member',            // default; will be recomputed below if linked member suggests higher
        createdAt: ts(),
        updatedAt: ts(),
      },
      { merge: true }
    );
  } else {
    await ref.set({ email, updatedAt: ts() }, { merge: true });
  }

  // Optional but recommended: recompute single role + sync claims
  await recomputeAndWriteUserRole(uid);

  logger.info('ensureUserDoc ok', { uid, email });
  return { ok: true };
});

/** NEW: called after signup + every login (client) */
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

  const highest = highestRoleFromArrays({
    userRole: user?.role || 'member',
    memberRoles: memberData?.roles || [],
    isPastorFlag: !!memberData?.isPastor,
  });

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

exports.setMemberPastorRole = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');
  const { memberId, makePastor } = req.data || {};
  if (!memberId || typeof makePastor !== 'boolean') throw new Error('invalid-argument');

  const allowed = await isUserPastorOrAdmin(uid);
  if (!allowed) throw new Error('permission-denied');

  await updateMemberAndLinkedUserRoles(memberId, {
    add: makePastor ? ['pastor'] : [],
    remove: makePastor ? [] : ['pastor'],
    setFlags: { isPastor: !!makePastor },
  });

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

  let setPastorFlag;
  if (rolesAdd.includes('pastor') && !rolesRemove.includes('pastor')) setPastorFlag = true;
  else if (rolesRemove.includes('pastor') && !rolesAdd.includes('pastor')) setPastorFlag = false;

  for (const mid of memberIds) {
    await updateMemberAndLinkedUserRoles(mid, {
      add: rolesAdd,
      remove: rolesRemove,
      setFlags: setPastorFlag === undefined ? {} : { isPastor: setPastorFlag },
    });
  }
  return { ok: true, updated: memberIds.length };
});

exports.promoteMeToAdmin = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');

  const existingAdmins = await listUidsByRole('admin');
  if (existingAdmins.length > 0) {
    const myRole = await getUserRole(uid);
    if (myRole !== 'admin') throw new Error('permission-denied');
  }

  await db.doc(`users/${uid}`).set(
    { role: 'admin', updatedAt: ts() },
    { merge: true }
  );

  const memberId = await getUserMemberId(uid);
  if (memberId) {
    await db.doc(`members/${memberId}`).set(
      { roles: admin.firestore.FieldValue.arrayUnion('admin'), updatedAt: ts() },
      { merge: true }
    );
  }

  await syncClaimsForUid(uid);
  return { ok: true };
});

/* Leaders can toggle member's leader role within a ministry */
exports.leaderSetMemberLeaderRole = onCall(async (req) => {
  const callerUid = req.auth?.uid;
  if (!callerUid) throw new Error('unauthenticated');

  const { memberId, ministryName, makeLeader } = req.data || {};
  if (!memberId || !ministryName || typeof makeLeader !== 'boolean') {
    throw new Error('invalid-argument');
  }

  const privileged = await isUserPastorOrAdmin(callerUid);
  const leadsThis = privileged ? true : await isUserLeaderOfMinistry(callerUid, ministryName);
  if (!leadsThis) throw new Error('permission-denied');

  const usersQ = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
  const linkedUid = usersQ.empty ? null : usersQ.docs[0].id;

  const memberRef = db.doc(`members/${memberId}`);
  const batch = db.batch();

  const memberUpdate = { updatedAt: ts() };
  if (makeLeader) {
    memberUpdate.roles = admin.firestore.FieldValue.arrayUnion('leader');
    memberUpdate.leadershipMinistries = admin.firestore.FieldValue.arrayUnion(ministryName);
  } else {
    memberUpdate.roles = admin.firestore.FieldValue.arrayRemove('leader');
    memberUpdate.leadershipMinistries = admin.firestore.FieldValue.arrayRemove(ministryName);
  }
  batch.set(memberRef, memberUpdate, { merge: true });

  if (!usersQ.empty) {
    const userRef = usersQ.docs[0].ref;
    const userUpdate = { updatedAt: ts() };
    if (makeLeader) {
      userUpdate.leadershipMinistries = admin.firestore.FieldValue.arrayUnion(ministryName);
    } else {
      userUpdate.leadershipMinistries = admin.firestore.FieldValue.arrayRemove(ministryName);
    }
    batch.set(userRef, userUpdate, { merge: true });
  }

  const mins = await db.collection('ministries').where('name', '==', ministryName).limit(1).get();
  if (!mins.empty && linkedUid) {
    const minRef = mins.docs[0].ref;
    batch.set(
      minRef,
      makeLeader
        ? { leaderUids: admin.firestore.FieldValue.arrayUnion(linkedUid), updatedAt: ts() }
        : { leaderUids: admin.firestore.FieldValue.arrayRemove(linkedUid), updatedAt: ts() },
      { merge: true }
    );
  }

  await batch.commit();

  if (linkedUid) await recomputeAndWriteUserRole(linkedUid);

  logger.info('leaderSetMemberLeaderRole', {
    callerUid,
    memberId,
    ministryName,
    makeLeader,
  });

  return { ok: true, memberId, ministryName, leader: makeLeader };
});
