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
    logger.error('getUser failed', uid, e);
    return null;
  }
}

async function getUserRoles(uid) {
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

async function listUidsByRole(roleLc) {
  const variants = [roleLc, roleLc.toUpperCase(), roleLc[0].toUpperCase() + roleLc.slice(1)];
  const results = await Promise.all(
    variants.map((r) => db.collection('users').where('roles', 'array-contains', r).get())
  );
  const set = new Set();
  results.forEach((qs) => qs.docs.forEach((d) => set.add(d.id)));
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

/* Only pastors (users.roles or member signals) */
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
  const roles = await getUserRoles(uid);
  if (roles.includes('pastor') || roles.includes('admin')) return true;

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

async function syncClaimsForUid(uid) {
  try {
    const roles = await getUserRoles(uid);
    const claims = {
      admin: roles.includes('admin') || undefined,
      pastor: roles.includes('pastor') || undefined,
      isAdmin: roles.includes('admin') || undefined,
      isPastor: roles.includes('pastor') || undefined,
      leader: roles.includes('leader') || undefined,
      isLeader: roles.includes('leader') || undefined,
    };
    await admin.auth().setCustomUserClaims(uid, claims);
  } catch (e) {
    logger.error('syncClaimsForUid failed', uid, e);
  }
}

/* Update member + linked user with roles */
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
    const userRef = usersQ.docs[0].ref;
    const userUpdate = { updatedAt: ts() };
    if (addLc.length) userUpdate.roles = admin.firestore.FieldValue.arrayUnion(...addLc);
    if (remLc.length) userUpdate.roles = admin.firestore.FieldValue.arrayRemove(...remLc);
    batch.update(userRef, userUpdate);
  }

  await batch.commit();
  if (uid) await syncClaimsForUid(uid);
}

/* Inbox (legacy) writer — kept for existing flows */
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

/* =========================
   Notifications collection
   ========================= */

async function writeNotification(payload) {
  // Always adds createdAt if caller forgot
  const data = { ...payload };
  if (!data.createdAt) data.createdAt = ts();
  await db.collection('notifications').add(data);
}

/** Broadcast to leaders/admins for a ministry (by name) */
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

/** Direct fan-out to each leader (by resolving members → users) */
async function writeDirectToLeaders({ ministryName, ministryDocId, joinRequestId, requestedByUid, requesterMemberId, type }) {
  // leaders as members
  const leadersSnap = await db
    .collection('members')
    .where('leadershipMinistries', 'array-contains', ministryName)
    .get();

  // additionally: ministries doc may store leader uids
  let ministryLeaderUids = [];
  const mins = await db
    .collection('ministries')
    .where('name', '==', ministryName)
    .limit(1)
    .get();
  if (!mins.empty) {
    const m = mins.docs[0].data() || {};
    ministryLeaderUids = Array.isArray(m.leaderIds) ? m.leaderIds.filter(Boolean) : [];
    ministryDocId = ministryDocId || mins.docs[0].id;
  }

  const batch = db.batch();

  // Fan-out via members→users
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

  // Fan-out via ministries.leaderIds (if present)
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

/** Direct to requester when approved/rejected */
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

    const { action, requestId, reason, byUid } = doc.data() || {};
    if (!action || !requestId || !byUid) {
      logger.warn('Invalid payload on approval action', doc.id);
      await doc.ref.update({ status: 'invalid', processed: true, processedAt: new Date() });
      return;
    }

    const allowed = await isUserPastorOrAdmin(byUid);
    if (!allowed) {
      logger.warn('Unauthorized approval action by', byUid);
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
    if (S(r.status || 'pending') !== 'pending') {
      await doc.ref.update({ status: 'already_processed', processed: true, processedAt: new Date() });
      return;
    }

    try {
      if (action === 'approve') {
        const minRef = db.collection('ministries').doc();
        const ministryName = S(r.name);
        const requestedByUid = S(r.requestedByUid) || byUid;

        // Create ministry + mark request approved
        await db.runTransaction(async (txn) => {
          txn.set(minRef, {
            id: minRef.id,
            name: ministryName,
            description: S(r.description),
            approved: true,
            createdAt: ts(),
            createdBy: requestedByUid,
            leaderIds: requestedByUid ? [requestedByUid] : [],
          });
          txn.update(reqRef, {
            status: 'approved',
            approvedMinistryId: minRef.id,
            updatedAt: ts(),
            approvedByUid: byUid,
          });
        });

        // Make requester leader & member
        if (requestedByUid) {
          const memberId = await getUserMemberId(requestedByUid);
          if (memberId) {
            await db.doc(`members/${memberId}`).set({
              ministries: admin.firestore.FieldValue.arrayUnion(ministryName),
              leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
              updatedAt: ts(),
            }, { merge: true });

            await updateMemberAndLinkedUserRoles(memberId, { add: ['leader'] });

            await db.doc(`users/${requestedByUid}`).set({
              leadershipMinistries: admin.firestore.FieldValue.arrayUnion(ministryName),
              roles: admin.firestore.FieldValue.arrayUnion('leader'),
              updatedAt: ts(),
            }, { merge: true });

            await syncClaimsForUid(requestedByUid);
          }
        }

        // Notify (legacy inbox) unchanged:
        if (requestedByUid) {
          await writeInbox(requestedByUid, {
            type: 'ministry_request_approved',
            channel: 'approvals',
            title: 'Your ministry was approved',
            body: `"${ministryName}" is now live.`,
            ministryId: minRef.id,
            ministryName,
            payload: { requestId, ministryId: minRef.id, ministryName },
            route: '/view-ministry',
            dedupeKey: `mcr_approved_${requestId}`,
          });
        }

        await writeInbox(byUid, {
          type: 'approval_action_processed',
          channel: 'approvals',
          title: 'Approved ministry request',
          body: `"${ministryName}" approved.`,
          ministryId: minRef.id,
          ministryName,
          payload: { requestId, action: 'approve' },
          route: '/pastor-approvals',
          dedupeKey: `mcr_action_${requestId}_approve_${byUid}`,
        });

        await doc.ref.update({ status: 'ok', processed: true, processedAt: new Date() });
      } else if (action === 'decline') {
        await reqRef.update({
          status: 'declined',
          declineReason: S(reason) || null,
          updatedAt: ts(),
          declinedByUid: byUid,
        });

        const requesterUid = S(r.requestedByUid);
        if (requesterUid) {
          await writeInbox(requesterUid, {
            type: 'ministry_request_declined',
            channel: 'approvals',
            title: 'Your ministry was declined',
            body: `"${S(r.name)}" was declined${S(reason) ? `: ${S(reason)}` : ''}`,
            ministryId: null,
            ministryName: S(r.name),
            payload: { requestId, ministryId: null, ministryName: S(r.name) },
            route: '/pastor-approvals',
            dedupeKey: `mcr_declined_${requestId}`,
          });
        }

        await writeInbox(byUid, {
          type: 'approval_action_processed',
          channel: 'approvals',
          title: 'Declined ministry request',
          body: `"${S(r.name)}" declined${S(reason) ? `: ${S(reason)}` : ''}`,
          ministryId: null,
          ministryName: S(r.name),
          payload: { requestId, action: 'decline' },
          route: '/pastor-approvals',
          dedupeKey: `mcr_action_${requestId}_decline_${byUid}`,
        });

        await doc.ref.update({ status: 'ok', processed: true, processedAt: new Date() });
      } else {
        await doc.ref.update({ status: 'unknown_action', processed: true, processedAt: new Date() });
      }
    } catch (e) {
      logger.error('processMinistryApprovalAction error', e);
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
   2) Notify pastors/admins for new ministry creation requests
   ========================================================= */
exports.onMinistryCreationRequestCreated = onDocumentCreated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const r = snap.data() || {};
    const name = S(r.name);

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
          ministryName: name,
          payload: { requestId: snap.id, ministryName: name },
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

    // Try to get ministry doc id (nice-to-have)
    let ministryDocId = null;
    const mins = await db
      .collection('ministries')
      .where('name', '==', ministryName)
      .limit(1)
      .get();
    if (!mins.empty) {
      ministryDocId = mins.docs[0].id;
    }

    // Broadcast for leaders/admins
    await writeLeaderBroadcast({
      ministryName,
      ministryDocId,
      joinRequestId: doc.id,
      requestedByUid,
      requesterMemberId: memberId,
      type: 'join_request',
    });

    // Fan-out to leaders (members→users) and ministries.leaderIds (if present)
    await writeDirectToLeaders({
      ministryName,
      ministryDocId,
      joinRequestId: doc.id,
      requestedByUid,
      requesterMemberId: memberId,
      type: 'join_request',
    });

    // (Optional) You can still keep your legacy inbox if desired (not required by app pages)
    // — omitted intentionally to avoid duplication.
  }
);

/* =========================================================
   4) Notify requester when join request status changes  ➜ /notifications
   ========================================================= */
exports.onJoinRequestUpdated = onDocumentUpdated(
  'join_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const prev = S(before.status || 'pending');
    const theNext = S(after.status || 'pending'); // ✅ fixed: declare const
    if (prev === theNext) return;

    if (theNext !== 'approved' && theNext !== 'rejected') return;

    const memberId = S(after.memberId);
    const ministryName = S(after.ministryId);
    let ministryDocId = S(after.ministryDocId) || null;

    if (!ministryDocId && ministryName) {
      const mins = await db
        .collection('ministries')
        .where('name', '==', ministryName)
        .limit(1)
        .get();
      if (!mins.empty) ministryDocId = mins.docs[0].id;
    }
    if (!memberId || !ministryName) return;

    const moderatorUid = S(after.moderatorUid) || null;

    await notifyRequesterResult({
      ministryName,
      ministryDocId,
      joinRequestId: event.params.id,
      requesterMemberId: memberId,
      result: theNext,
      moderatorUid,
    });

    // (Optional legacy inbox mirror was here; omitted to prevent duplication.)
  }
);

/* =========================================================
   4b) Notify leaders when a pending join request is deleted (cancelled)  ➜ /notifications
   ========================================================= */
exports.onJoinRequestDeleted = onDocumentDeleted(
  'join_requests/{id}',
  async (event) => {
    const r = event.data?.data() || {};
    const status = S(r.status || 'pending');

    // Notify leaders only when a pending req is cancelled by requester
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
   5) Notify pastors when a prayer request is submitted (legacy inbox)
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
   6) CALLABLES — role sync
   ========================================================= */
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
    const isAdmin = (await getUserRoles(uid)).includes('admin');
    if (!isAdmin) throw new Error('permission-denied');
  }

  await db.doc(`users/${uid}`).set(
    { roles: admin.firestore.FieldValue.arrayUnion('admin'), updatedAt: ts() },
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

exports.ensureMemberLeaderRole = onCall(async (req) => {
  const uid = req.auth?.uid;
  if (!uid) throw new Error('unauthenticated');
  const { memberId } = req.data || {};
  if (!memberId) throw new Error('invalid-argument');

  const isAdmin = (await getUserRoles(uid)).includes('admin');
  const myMemberId = await getUserMemberId(uid);
  if (!(isAdmin || myMemberId === memberId)) throw new Error('permission-denied');

  await updateMemberAndLinkedUserRoles(memberId, { add: ['leader'] });
  return { ok: true };
});
