/* functions/index.js */
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();

// Match your deployed region
setGlobalOptions({ region: 'europe-west2' });

/* ========= Helpers ========= */
const S = (v) => (v ?? '').toString();

async function getUserRoles(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  const roles = (snap.data()?.roles) || [];
  return Array.isArray(roles) ? roles : [];
}

async function listUidsByRole(role) {
  const qs = await db.collection('users').where('roles', 'array-contains', role).get();
  return qs.docs.map(d => d.id);
}

async function listPastorAndAdminUids() {
  const [pastors, admins] = await Promise.all([listUidsByRole('pastor'), listUidsByRole('admin')]);
  const set = new Set([...pastors, ...admins]); // no dupes
  return Array.from(set);
}

async function writeInbox(uid, payload) {
  await db.collection('inbox').doc(uid).set(
    { lastSeenAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true }
  );
  await db.collection('inbox').doc(uid).collection('events').add({
    ...payload,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/* =========================================================
   1) Process approval actions (approve | decline) – secure
   Client writes to /ministry_approval_actions; server does the work.
   ========================================================= */
exports.processMinistryApprovalAction = onDocumentCreated(
  'ministry_approval_actions/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;

    const { action, requestId, reason, byUid } = doc.data() || {};
    if (!action || !requestId || !byUid) {
      logger.warn('Invalid payload on approval action', doc.id);
      await doc.ref.update({ status: 'invalid', processedAt: new Date() });
      return;
    }

    // Authorize actor
    const roles = await getUserRoles(byUid);
    const allowed = roles.includes('pastor') || roles.includes('admin');
    if (!allowed) {
      logger.warn('Unauthorized approval action by', byUid, roles);
      await doc.ref.update({ status: 'denied', processedAt: new Date() });
      return;
    }

    const reqRef = db.doc(`ministry_creation_requests/${requestId}`);
    const reqSnap = await reqRef.get();
    if (!reqSnap.exists) {
      await doc.ref.update({ status: 'not_found', processedAt: new Date() });
      return;
    }
    const r = reqSnap.data();
    if (S(r.status || 'pending') !== 'pending') {
      await doc.ref.update({ status: 'already_processed', processedAt: new Date() });
      return;
    }

    try {
      if (action === 'approve') {
        const minRef = db.collection('ministries').doc();

        await db.runTransaction(async (txn) => {
          txn.set(minRef, {
            id: minRef.id,
            name: S(r.name),
            description: S(r.description),
            approved: true,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: S(r.requestedByUid) || byUid,
            leaderIds: S(r.requestedByUid) ? [S(r.requestedByUid)] : [],
          });
          txn.update(reqRef, {
            status: 'approved',
            approvedMinistryId: minRef.id,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            approvedByUid: byUid,
          });
        });

        // Notify requester in inbox
        const requesterUid = S(r.requestedByUid);
        if (requesterUid) {
          await writeInbox(requesterUid, {
            type: 'ministry_request_approved',
            channel: 'approvals',
            title: 'Your ministry was approved',
            body: `"${S(r.name)}" is now live.`,
            ministryId: minRef.id,
            ministryName: S(r.name),
            payload: { requestId, ministryId: minRef.id, ministryName: S(r.name) },
            route: '/pastor-approvals',
          });
        }

        // Optional: confirm to approver too
        await writeInbox(byUid, {
          type: 'approval_action_processed',
          channel: 'approvals',
          title: 'Approved ministry request',
          body: `"${S(r.name)}" approved.`,
          ministryId: minRef.id,
          ministryName: S(r.name),
          payload: { requestId, action: 'approve' },
          route: '/pastor-approvals',
        });

        await doc.ref.update({ status: 'ok', processedAt: new Date() });
      } else if (action === 'decline') {
        await reqRef.update({
          status: 'declined',
          declineReason: S(reason) || null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
        });

        await doc.ref.update({ status: 'ok', processedAt: new Date() });
      } else {
        await doc.ref.update({ status: 'unknown_action', processedAt: new Date() });
      }
    } catch (e) {
      logger.error('processMinistryApprovalAction error', e);
      await doc.ref.update({ status: 'error', error: (e && e.message) || String(e), processedAt: new Date() });
    }
  }
);

/* =========================================================
   2) Notify pastors & admins when a new ministry request is submitted
   (fires when leaders create /ministry_creation_requests doc)
   ========================================================= */
exports.onMinistryCreationRequestCreated = onDocumentCreated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const r = snap.data();
    const name = S(r.name);

    // Notify BOTH roles to be safe
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
        })
      )
    );
  }
);

/* =========================================================
   3) JOIN REQUESTS: notify ministry leaders when a join request is created
   ========================================================= */
exports.onJoinRequestCreated = onDocumentCreated(
  'join_requests/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;
    const jr = doc.data();
    const memberId = S(jr.memberId);
    const ministryName = S(jr.ministryId); // "name" in your schema
    if (!ministryName) return;

    const mins = await db.collection('ministries')
      .where('name', '==', ministryName)
      .where('approved', '==', true)
      .limit(1)
      .get();
    if (mins.empty) return;

    const minDoc = mins.docs[0];
    const ministry = minDoc.data();
    const leaderIds = Array.isArray(ministry.leaderIds) ? ministry.leaderIds : [];

    // Requester name
    let requesterName = 'Member';
    if (memberId) {
      const memSnap = await db.doc(`members/${memberId}`).get();
      if (memSnap.exists) {
        const m = memSnap.data() || {};
        const full = S(m.fullName);
        const fn = S(m.firstName);
        const ln = S(m.lastName);
        requesterName = full || [fn, ln].filter(Boolean).join(' ') || 'Member';
      }
    }

    await Promise.all(
      leaderIds.map((uid) =>
        writeInbox(uid, {
          type: 'join_request_created',
          channel: 'joinreq',
          title: `Join request from ${requesterName}`,
          body: `Ministry: ${ministryName}`,
          ministryId: minDoc.id,
          ministryName,
          payload: {
            joinRequestId: doc.id,
            memberId,
            ministryId: ministryName, // legacy naming in your app
            ministryName,
            requesterName,
          },
          route: '/leader-join-requests',
        })
      )
    );
  }
);

/* =========================================================
   4) JOIN REQUESTS: notify requester on status change
   ========================================================= */
exports.onJoinRequestUpdated = onDocumentUpdated(
  'join_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const prev = S(before.status || 'pending');
    const next = S(after.status || 'pending');
    if (prev === next) return;

    const memberId = S(after.memberId);
    const ministryName = S(after.ministryId);
    let toUid = S(after.requestedByUid);

    if (!toUid && memberId) {
      const users = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
      if (!users.empty) toUid = users.docs[0].id;
    }
    if (!toUid) return;

    const pretty = next[0]?.toUpperCase() + next.slice(1);
    await writeInbox(toUid, {
      type: 'join_request_status',
      channel: 'joinreq',
      title: `Join request ${pretty}`,
      body: ministryName ? `Ministry: ${ministryName}` : '',
      ministryId: null,
      ministryName,
      payload: {
        joinRequestId: event.params.id,
        memberId,
        ministryId: ministryName, // legacy
        ministryName,
        status: next,
      },
      route: '/my-join-requests',
    });
  }
);
