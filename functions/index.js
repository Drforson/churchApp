/* functions/index.js */
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();

// Adjust region to your deployment region
setGlobalOptions({ region: 'europe-west2' });

/* ===========================
   Helpers
   =========================== */
function safeStr(v) {
  return (v ?? '').toString();
}

async function getUserRoles(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  const roles = (snap.data()?.roles) || [];
  return Array.isArray(roles) ? roles : [];
}

async function listPastorUids() {
  const qs = await db.collection('users').where('roles', 'array-contains', 'pastor').get();
  return qs.docs.map((d) => d.id);
}

async function writeInbox(uid, payload) {
  // Ensure inbox doc exists (also used for lastSeenAt)
  await db.collection('inbox').doc(uid).set(
    { lastSeenAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
  // Store event
  await db.collection('inbox').doc(uid).collection('events').add({
    ...payload,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/* ===========================
   1) Process Ministry Approval Actions (approve | decline)
   Client writes to /ministry_approval_actions; server does privileged writes.
   =========================== */
exports.processMinistryApprovalAction = onDocumentCreated(
  'ministry_approval_actions/{id}',
  async (event) => {
    const ref = event.data;
    if (!ref) return;

    const act = ref.data();
    const { action, requestId, reason, byUid } = act || {};

    if (!action || !requestId || !byUid) {
      logger.warn('Invalid approval action payload', act);
      await ref.ref.update({ status: 'invalid', processedAt: new Date() });
      return;
    }

    // Authorize actor
    const roles = await getUserRoles(byUid);
    const allowed = roles.includes('pastor') || roles.includes('admin');
    if (!allowed) {
      logger.warn('Unauthorized approval action by', byUid, roles);
      await ref.ref.update({ status: 'denied', processedAt: new Date() });
      return;
    }

    const reqRef = db.doc(`ministry_creation_requests/${requestId}`);
    const reqSnap = await reqRef.get();
    if (!reqSnap.exists) {
      await ref.ref.update({ status: 'not_found', processedAt: new Date() });
      return;
    }
    const r = reqSnap.data();
    const currentStatus = safeStr(r.status || 'pending');
    if (currentStatus !== 'pending') {
      await ref.ref.update({ status: 'already_processed', processedAt: new Date() });
      return;
    }

    try {
      if (action === 'approve') {
        // Prepare a new ministry id so we can include it in notifications
        const minRef = db.collection('ministries').doc();

        await db.runTransaction(async (txn) => {
          txn.set(minRef, {
            id: minRef.id,
            name: safeStr(r.name),
            description: safeStr(r.description),
            approved: true,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: safeStr(r.requestedByUid) || byUid,
            leaderIds: safeStr(r.requestedByUid) ? [safeStr(r.requestedByUid)] : [],
          });

          txn.update(reqRef, {
            status: 'approved',
            approvedMinistryId: minRef.id,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            approvedByUid: byUid,
          });
        });

        // Notify requester (inbox)
        const requesterUid = safeStr(r.requestedByUid);
        if (requesterUid) {
          await writeInbox(requesterUid, {
            type: 'ministry_request_approved',
            channel: 'approvals',
            title: 'Your ministry was approved',
            body: `"${safeStr(r.name)}" is now live.`,
            // convenience top-level for your NotificationCenterPage:
            ministryId: minRef.id,
            ministryName: safeStr(r.name),
            // payload for future-proof linking
            payload: {
              requestId,
              ministryId: minRef.id,
              ministryName: safeStr(r.name),
            },
            route: '/pastor-approvals',
          });
        }

        await ref.ref.update({ status: 'ok', processedAt: new Date() });
      } else if (action === 'decline') {
        await reqRef.update({
          status: 'declined',
          declineReason: safeStr(reason) || null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          declinedByUid: byUid,
        });

        const requesterUid = safeStr(r.requestedByUid);
        if (requesterUid) {
          await writeInbox(requesterUid, {
            type: 'ministry_request_declined',
            channel: 'approvals',
            title: 'Your ministry was declined',
            body: `"${safeStr(r.name)}" was declined${safeStr(reason) ? `: ${safeStr(reason)}` : ''}`,
            ministryId: null,
            ministryName: safeStr(r.name),
            payload: {
              requestId,
              ministryId: null,
              ministryName: safeStr(r.name),
            },
            route: '/pastor-approvals',
          });
        }

        await ref.ref.update({ status: 'ok', processedAt: new Date() });
      } else {
        await ref.ref.update({ status: 'unknown_action', processedAt: new Date() });
      }
    } catch (e) {
      logger.error('processMinistryApprovalAction error', e);
      await ref.ref.update({
        status: 'error',
        error: (e && e.message) || String(e),
        processedAt: new Date(),
      });
    }
  }
);

/* ===========================
   2) Notify pastors when a new ministry creation request is submitted
   =========================== */
exports.onMinistryCreationRequestCreated = onDocumentCreated(
  'ministry_creation_requests/{id}',
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const r = snap.data();
    const name = safeStr(r.name);
    const pastors = await listPastorUids();

    await Promise.all(
      pastors.map((uid) =>
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

/* ===========================
   3) JOIN REQUESTS: notify leaders when created
   Each join_requests doc contains { memberId, ministryId (actually name) ... }
   =========================== */
exports.onJoinRequestCreated = onDocumentCreated(
  'join_requests/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;
    const jr = doc.data();
    const memberId = safeStr(jr.memberId);
    const ministryName = safeStr(jr.ministryId);
    if (!ministryName) return;

    // Find ministry doc by name
    const mins = await db
      .collection('ministries')
      .where('name', '==', ministryName)
      .where('approved', '==', true)
      .limit(1)
      .get();

    if (mins.empty) return;
    const ministryDoc = mins.docs[0];
    const ministry = ministryDoc.data();
    const leaderIds = Array.isArray(ministry.leaderIds) ? ministry.leaderIds : [];

    // Resolve requester name (from members/{memberId})
    let requesterName = 'Member';
    if (memberId) {
      const memSnap = await db.doc(`members/${memberId}`).get();
      if (memSnap.exists) {
        const m = memSnap.data() || {};
        const full = safeStr(m.fullName);
        const fn = safeStr(m.firstName);
        const ln = safeStr(m.lastName);
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
          ministryId: ministryDoc.id,
          ministryName,
          payload: {
            joinRequestId: doc.id,
            memberId,
            ministryId: ministryName, // legacy compatibility
            ministryName,
            requesterName,
          },
          route: '/leader-join-requests',
        })
      )
    );
  }
);

/* ===========================
   4) JOIN REQUESTS: notify requester when status changes
   Leaders/Admins update join_requests.status. We notify the requester.
   =========================== */
exports.onJoinRequestUpdated = onDocumentUpdated(
  'join_requests/{id}',
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const prev = safeStr(before.status || 'pending');
    const next = safeStr(after.status || 'pending');
    if (prev === next) return;

    const memberId = safeStr(after.memberId);
    const ministryName = safeStr(after.ministryId);
    let toUid = safeStr(after.requestedByUid);

    // If requestedByUid missing, try resolve via users.memberId
    if (!toUid && memberId) {
      const users = await db.collection('users').where('memberId', '==', memberId).limit(1).get();
      if (!users.empty) toUid = users.docs[0].id;
    }
    if (!toUid) return;

    const pretty = next.charAt(0).toUpperCase() + next.slice(1);
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
