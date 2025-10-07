/* functions/index.js */
const { onDocumentCreated, onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions, logger } = require('firebase-functions/v2');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ts = admin.firestore.FieldValue.serverTimestamp;

// Match your deployed region
setGlobalOptions({ region: 'europe-west2' });

/* ========= Helpers (robust) ========= */
const S = (v) => (v ?? '').toString().trim();

/** Users -> roles[] (lowercased) */
async function getUserRoles(uid) {
  const snap = await db.doc(`users/${uid}`).get();
  const raw = snap.data()?.roles ?? [];
  const arr = Array.isArray(raw) ? raw : (typeof raw === 'string' ? raw.split(',') : []);
  return arr.map((r) => String(r).toLowerCase().trim()).filter(Boolean);
}

/** List UIDs who have a role in users.roles (handle casing by querying a few variants) */
async function listUidsByRole(roleLc) {
  const variants = [roleLc, roleLc.toUpperCase(), roleLc[0].toUpperCase() + roleLc.slice(1)];
  const results = await Promise.all(
    variants.map((r) => db.collection('users').where('roles', 'array-contains', r).get())
  );
  const set = new Set();
  results.forEach((qs) => qs.docs.forEach((d) => set.add(d.id)));
  return Array.from(set);
}

/** Map memberId[] -> user uid[] using users.memberId (chunked whereIn to 10) */
async function uidsFromMemberIds(memberIds) {
  const out = new Set();
  for (let i = 0; i < memberIds.length; i += 10) {
    const chunk = memberIds.slice(i, i + 10);
    const qs = await db.collection('users').where('memberId', 'in', chunk).get();
    qs.docs.forEach((d) => out.add(d.id));
  }
  return Array.from(out);
}

/** Fallback: collect memberIds that look like pastors/admins */
async function listMemberIdsByPastorOrAdmin() {
  const out = new Set();

  // members.roles contains 'pastor' / 'admin' (all common casings)
  for (const val of ['pastor', 'Pastor', 'PASTOR']) {
    const qs = await db.collection('members').where('roles', 'array-contains', val).get();
    qs.docs.forEach((d) => out.add(d.id));
  }
  for (const val of ['admin', 'Admin', 'ADMIN']) {
    const qs = await db.collection('members').where('roles', 'array-contains', val).get();
    qs.docs.forEach((d) => out.add(d.id));
  }

  // members.isPastor == true
  {
    const qs = await db.collection('members').where('isPastor', '==', true).get();
    qs.docs.forEach((d) => out.add(d.id));
  }

  // leadershipMinistries heuristic — fetch a small window and filter
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

/** Union of:
 *  - users with role=admin/pastor
 *  - users linked to member records that imply pastor/admin
 */
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

/**
 * Write a personal inbox event.
 * - Marks as unread (read:false)
 * - Supports optional dedupe with payload.dedupeKey (skip if exists)
 */
async function writeInbox(uid, payload) {
  await db.collection('inbox').doc(uid).set(
    { lastSeenAt: ts() },
    { merge: true }
  );

  const toWrite = {
    ...payload,
    read: false,
    createdAt: ts(),
  };

  if (payload && payload.dedupeKey) {
    const qs = await db
      .collection('inbox').doc(uid).collection('events')
      .where('dedupeKey', '==', payload.dedupeKey)
      .limit(1).get();
    if (!qs.empty) {
      // Already have one; optionally refresh timestamp:
      await qs.docs[0].ref.update({ createdAt: ts(), read: false });
      return;
    }
    toWrite.dedupeKey = payload.dedupeKey;
  }

  await db.collection('inbox').doc(uid).collection('events').add(toWrite);
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

    // Authorize actor (defense-in-depth; rules should already enforce)
    const roles = await getUserRoles(byUid);
    let allowed = roles.includes('pastor') || roles.includes('admin');
    if (!allowed) {
      try {
        const userRec = await admin.auth().getUser(byUid);
        const claims = userRec.customClaims || {};
        if (claims.pastor === true || claims.admin === true || claims.isPastor === true || claims.isAdmin === true) {
          allowed = true;
        }
      } catch (_) {}
    }
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
    const r = reqSnap.data() || {};
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
            createdAt: ts(),
            createdBy: S(r.requestedByUid) || byUid,
            leaderIds: S(r.requestedByUid) ? [S(r.requestedByUid)] : [],
          });
          txn.update(reqRef, {
            status: 'approved',
            approvedMinistryId: minRef.id,
            updatedAt: ts(),
            approvedByUid: byUid,
          });
        });

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
            route: '/view-ministry',
            routeArgs: { ministryId: minRef.id, ministryName: S(r.name) },
            dedupeKey: `mcr_approved_${requestId}`,
          });
        }

        await writeInbox(byUid, {
          type: 'approval_action_processed',
          channel: 'approvals',
          title: 'Approved ministry request',
          body: `"${S(r.name)}" approved.`,
          ministryId: minRef.id,
          ministryName: S(r.name),
          payload: { requestId, action: 'approve' },
          route: '/pastor-approvals',
          dedupeKey: `mcr_action_${requestId}_approve_${byUid}`,
        });

        await doc.ref.update({ status: 'ok', processedAt: new Date() });
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
   3) JOIN REQUESTS: notify ministry leaders when a join request is created
   ========================================================= */
exports.onJoinRequestCreated = onDocumentCreated(
  'join_requests/{id}',
  async (event) => {
    const doc = event.data;
    if (!doc) return;
    const jr = doc.data() || {};
    const memberId = S(jr.memberId);
    const ministryName = S(jr.ministryId); // your app uses the ministry "name" here
    if (!ministryName) return;

    const mins = await db.collection('ministries')
      .where('name', '==', ministryName)
      .where('approved', '==', true)
      .limit(1)
      .get();
    if (mins.empty) return;

    const minDoc = mins.docs[0];
    const ministry = minDoc.data() || {};
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
            ministryId: ministryName, // legacy naming in app
            ministryName,
            requesterName,
          },
          route: '/leader-join-requests',
          dedupeKey: `jr_leader_${doc.id}_${uid}`,
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
      dedupeKey: `jr_me_${event.params.id}_${next}_${toUid}`,
    });
  }
);
