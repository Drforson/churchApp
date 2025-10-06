// functions/index.js

// -----------------------------
// Firebase Functions v2 imports
// -----------------------------
const { onCall } = require("firebase-functions/v2/https");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { setGlobalOptions } = require("firebase-functions/v2/options");

// -----------------------------
// Firebase Admin SDK
// -----------------------------
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// ----------------------------------------
// Global options (region, memory if needed)
// ----------------------------------------
setGlobalOptions({ region: "europe-west2" });

// ----------------------------------------
// Admin init
// ----------------------------------------
initializeApp();
const db = getFirestore();

// ----------------------------------------
// Helpers (existing + new)
// ----------------------------------------
const s = (v) => (typeof v === "string" ? v : "");
const HttpsError = (code, message) => { const err = new Error(message); err.code = code; return err; };

const requireAuth = (request) => {
  const auth = request.auth;
  if (!auth) throw HttpsError("unauthenticated", "Sign in required.");
  return auth;
};

const getUserRoles = async (uid) => {
  const snap = await db.collection("users").doc(uid).get();
  const roles = snap.data()?.roles ?? [];
  return Array.isArray(roles) ? roles.map((r) => String(r).toLowerCase()) : [];
};

const hasRole = (roles, role) => Array.isArray(roles) && roles.includes(String(role).toLowerCase());

const requireAdmin = async (uid) => {
  const roles = await getUserRoles(uid);
  if (!hasRole(roles, "admin")) throw HttpsError("permission-denied", "Admin role required.");
  return true;
};

const requireLeaderOrAdmin = async (uid) => {
  const roles = await getUserRoles(uid);
  if (!hasRole(roles, "leader") && !hasRole(roles, "admin")) {
    throw HttpsError("permission-denied", "Leader or admin role required.");
  }
  return true;
};

const requirePastorOrAdmin = async (uid) => {
  const roles = await getUserRoles(uid);
  if (!hasRole(roles, "pastor") && !hasRole(roles, "admin")) {
    throw HttpsError("permission-denied", "Pastor or admin role required.");
  }
  return true;
};

const getLinkedUserUidForMember = async (memberId) => {
  if (!memberId) return null;
  const q = await db.collection("users").where("memberId", "==", memberId).limit(1).get();
  return q.empty ? null : q.docs[0].id;
};

// Convert various client shapes to a JS Date (or null)
const coerceDate = (v) => {
  if (!v) return null;
  if (v instanceof Date) return v;
  if (typeof v === "number") return new Date(v); // millis
  if (typeof v === "string") {
    const d = new Date(v);
    return isNaN(d) ? null : d;
  }
  if (typeof v === "object" && typeof v._seconds === "number") {
    const ms = v._seconds * 1000 + Math.floor((v._nanoseconds || 0) / 1e6);
    return new Date(ms);
  }
  return null;
};

// Whitelist for create payload
const ALLOWED_CREATE_FIELDS = new Set([
  "firstName", "lastName", "fullName", "email", "phoneNumber",
  "gender", "address", "emergencyContactName", "emergencyContactNumber",
  "maritalStatus", "dateOfBirth",
]);

const pickAllowed = (data) => {
  const out = {};
  for (const k of Object.keys(data || {})) {
    if (!ALLOWED_CREATE_FIELDS.has(k)) continue;
    if (k === "dateOfBirth") {
      const d = coerceDate(data[k]);
      if (d) out[k] = d;
    } else {
      out[k] = data[k];
    }
  }
  return out;
};

// Convenience: compute fullNameLower for sorting
const computeFullNameLower = (mData = {}) => {
  const full = s(mData.fullName) || `${s(mData.firstName)} ${s(mData.lastName)}`.trim();
  return full.trim().toLowerCase();
};

// Simple notification writer
async function writeNotification(payload) {
  // payload: { toUid?, toRole?, toRequester?, requestId?, title, body, type, route?, ministryId?, ministryName?, status? }
  await db.collection("notifications").add({
    ...payload,
    createdAt: FieldValue.serverTimestamp(),
    read: false,
  });
}

// Helpers for join-requests notifications
async function getMinistryByName(name) {
  if (!name) return null;
  const q = await db.collection("ministries").where("name", "==", name).limit(1).get();
  if (q.empty) return null;
  return { id: q.docs[0].id, data: q.docs[0].data() || {} };
}
async function getMemberDisplay(memberId) {
  if (!memberId) return { name: "Member", data: {} };
  const snap = await db.collection("members").doc(memberId).get();
  const d = snap.data() || {};
  const name = s(d.fullName) || `${s(d.firstName)} ${s(d.lastName)}`.trim() || "Member";
  return { name, data: d };
}

/* ----------------------------------------
   Canary callable
---------------------------------------- */
exports.ping = onCall(() => ({ ok: true, pong: true }));

/* ----------------------------------------
   Promote current signed-in user to Admin
---------------------------------------- */
const ALLOWLIST_EMAILS = [
  "forsonalfred21@gmail.com",
  "carlos@gmail.com",
  "admin@gmail.com",
];

exports.promoteMeToAdmin = onCall(async (request) => {
  const auth = requireAuth(request);

  const email = auth.token.email || "";
  const isEmulator =
    !!process.env.FIREBASE_AUTH_EMULATOR_HOST ||
    !!process.env.FIRESTORE_EMULATOR_HOST;

  if (!isEmulator && !ALLOWLIST_EMAILS.includes(email)) {
    throw HttpsError("permission-denied", "Not on allowlist.");
  }

  const uid = auth.uid;
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    throw HttpsError("failed-precondition", "User doc not found.");
  }

  const memberId = (userSnap.data() || {}).memberId || null;

  await userRef.set({ roles: FieldValue.arrayUnion("admin") }, { merge: true });

  if (memberId) {
    await db.collection("members").doc(memberId).set(
      { roles: FieldValue.arrayUnion("admin") },
      { merge: true }
    );
  }

  return { ok: true, uid, memberId };
});

/* ----------------------------------------
   Create & link a member (server-side)
---------------------------------------- */
exports.createMember = onCall(async (request) => {
  const auth = requireAuth(request);
  const uid = auth.uid;
  const now = FieldValue.serverTimestamp();

  const result = await db.runTransaction(async (tx) => {
    const userRef = db.collection("users").doc(uid);
    const userSnap = await tx.get(userRef);
    const userData = userSnap.data() || {};

    if (userData.memberId && typeof userData.memberId === "string" && userData.memberId.length) {
      return { ok: true, memberId: userData.memberId, alreadyLinked: true };
    }

    const raw = request.data || {};
    const payload = pickAllowed(raw);

    const memberRef = db.collection("members").doc();
    const fullNameLower = computeFullNameLower(payload);

    tx.set(memberRef, {
      ...payload,
      fullNameLower,
      createdAt: now,
      updatedAt: now,
      createdByUid: uid,
      userUid: uid,
    });

    tx.set(
      userRef,
      {
        memberId: memberRef.id,
        linkedAt: now,
        email: auth.token?.email || userData.email || null,
        createdAt: userSnap.exists ? userData.createdAt ?? now : now,
      },
      { merge: true }
    );

    return { ok: true, memberId: memberRef.id, alreadyLinked: false };
  });

  return result;
});

/* ========================================================================
   Join Requests: Notifications
   ======================================================================== */

// When a join request is created → notify ministry leaders
exports.onJoinRequestCreate = onDocumentCreated("join_requests/{requestId}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const jr = snap.data() || {};

  const ministryName = s(jr.ministryId); // NOTE: your app uses 'ministryId' to store the name
  const memberId = s(jr.memberId);

  // Resolve ministry by name to get leaderIds + an id for deep-link
  const min = await getMinistryByName(ministryName);
  const ministryId = min?.id || null;
  const leaderIds = Array.isArray(min?.data.leaderIds) ? min.data.leaderIds : [];

  // Get requester display name for a friendlier message
  const member = await getMemberDisplay(memberId);

  if (leaderIds.length === 0) {
    // No leaders set; nothing to direct notify. (Optionally notify pastors.)
    await writeNotification({
      toRole: "pastor",
      type: "join_request_created",
      title: "Join request received",
      body: `${member.name} requested to join ${ministryName}`,
      route: ministryId ? "/view-ministry" : undefined,
      ministryId: ministryId || undefined,
      ministryName,
    });
    return;
  }

  // Notify each leader directly
  await Promise.all(
    leaderIds.map((leaderUid) =>
      writeNotification({
        toUid: String(leaderUid),
        type: "join_request_created",
        title: "New join request",
        body: `${member.name} requested to join ${ministryName}`,
        route: ministryId ? "/view-ministry" : undefined,
        ministryId: ministryId || undefined,
        ministryName,
      })
    )
  );
});

// When status changes (pending → approved|declined) → notify requester
exports.onJoinRequestStatusChange = onDocumentUpdated("join_requests/{requestId}", async (event) => {
  const before = event.data?.before?.data() || {};
  const after = event.data?.after?.data() || {};

  const prev = s(before.status || "pending").toLowerCase();
  const curr = s(after.status || "pending").toLowerCase();

  if (prev === curr) return; // no change

  const ministryName = s(after.ministryId); // name stored in field
  const memberId = s(after.memberId);
  const min = await getMinistryByName(ministryName);
  const ministryId = min?.id || null;

  // requester uid preference: field from doc, else resolve via memberId→user
  const requesterUid = s(after.requestedByUid) || (await getLinkedUserUidForMember(memberId));
  if (!requesterUid) return; // nothing we can do

  if (curr === "approved") {
    await writeNotification({
      toUid: requesterUid,
      type: "join_request_status",
      status: "approved",
      title: "Join request approved",
      body: `You're approved to join ${ministryName}.`,
      route: ministryId ? "/view-ministry" : undefined,
      ministryId: ministryId || undefined,
      ministryName,
    });

    // (Optional) Add the ministry to the member's list here if your leader UI doesn't:
    // await db.collection("members").doc(memberId).set({
    //   ministries: FieldValue.arrayUnion(ministryName)
    // }, { merge: true });

  } else if (curr === "declined") {
    const reason = s(after.reason) || s(after.declineReason);
    await writeNotification({
      toUid: requesterUid,
      type: "join_request_status",
      status: "declined",
      title: "Join request declined",
      body: reason ? `Your request to join ${ministryName} was declined: ${reason}`
                   : `Your request to join ${ministryName} was declined.`,
      route: ministryId ? "/view-ministry" : undefined,
      ministryId: ministryId || undefined,
      ministryName,
    });
  }
});

/* ========================================================================
   Ministry Creation Approval Flow
   ======================================================================== */

// Leaders/Admins submit a request for a new ministry → notify pastors
exports.requestCreateMinistry = onCall(async (request) => {
  const auth = requireAuth(request);
  const uid = auth.uid;

  await requireLeaderOrAdmin(uid);

  const nameRaw = s(request.data?.name).trim();
  const description = s(request.data?.description);
  const requestedByUid = s(request.data?.requestedByUid) || uid;
  const requestedByMemberId = s(request.data?.requestedByMemberId);

  if (!nameRaw) throw HttpsError("invalid-argument", "name is required.");

  // Avoid duplicate pending by name
  const dup = await db.collection("ministry_creation_requests")
    .where("name", "==", nameRaw)
    .where("status", "==", "pending")
    .limit(1).get();
  if (!dup.empty) return { ok: true, info: "Already pending." };

  const reqRef = db.collection("ministry_creation_requests").doc();

  await reqRef.set({
    id: reqRef.id,
    name: nameRaw,
    description,
    status: "pending", // pending | approved | declined
    requestedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    requestedByUid,
    requestedByMemberId: requestedByMemberId || null,
    requesterEmail: auth.token?.email || null,
  });

  await writeNotification({
    toRole: "pastor",
    type: "ministry_request",
    title: "New ministry creation request",
    body: `${nameRaw} submitted for approval`,
    route: "/pastor-approvals", // deep-link for pastors
    ministryName: nameRaw,
    requestId: reqRef.id,
  });

  return { ok: true, id: reqRef.id };
});

// Pastors/Admins approve → create ministry + notify requester
exports.approveMinistryCreation = onCall(async (request) => {
  const auth = requireAuth(request);
  const uid = auth.uid;
  await requirePastorOrAdmin(uid);

  const requestId = s(request.data?.requestId);
  if (!requestId) throw HttpsError("invalid-argument", "requestId required.");

  const reqRef = db.collection("ministry_creation_requests").doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) throw HttpsError("not-found", "Request not found.");

  const r = reqSnap.data();
  if (r.status !== "pending") return { ok: true, info: "Already processed." };

  const name = s(r.name);
  const description = s(r.description);
  const requesterUid = s(r.requestedByUid);

  await db.runTransaction(async (tx) => {
    const minRef = db.collection("ministries").doc();
    tx.set(minRef, {
      name,
      description,
      leaderIds: requesterUid ? [requesterUid] : [],
      createdBy: requesterUid || uid,
      approved: true,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    tx.update(reqRef, {
      status: "approved",
      approvedMinistryId: minRef.id,
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (requesterUid) {
      const nRef = db.collection("notifications").doc();
      tx.set(nRef, {
        toUid: requesterUid,
        type: "ministry_request_result",
        title: "Ministry approved",
        body: `${name} has been approved.`,
        route: "/view-ministry",
        ministryId: minRef.id,
        ministryName: name,
        createdAt: FieldValue.serverTimestamp(),
        read: false,
      });
    }
  });

  return { ok: true, requestId };
});

// Pastors/Admins decline → mark declined + notify requester
exports.declineMinistryCreation = onCall(async (request) => {
  const auth = requireAuth(request);
  const uid = auth.uid;
  await requirePastorOrAdmin(uid);

  const requestId = s(request.data?.requestId);
  const reason = s(request.data?.reason); // optional
  if (!requestId) throw HttpsError("invalid-argument", "requestId required.");

  const reqRef = db.collection("ministry_creation_requests").doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) throw HttpsError("not-found", "Request not found.");

  const r = reqSnap.data();
  if (r.status !== "pending") return { ok: true, info: "Already processed." };

  await reqRef.update({
    status: "declined",
    declineReason: reason || null,
    updatedAt: FieldValue.serverTimestamp(),
  });

  const requesterUid = s(r.requestedByUid);
  if (requesterUid) {
    await writeNotification({
      toUid: requesterUid,
      type: "ministry_request_result",
      title: "Ministry declined",
      body: reason ? `${r.name} was declined: ${reason}` : `${r.name} was declined.`,
      ministryName: s(r.name),
    });
  }

  return { ok: true, requestId };
});

/* -----------------------------------------------------------------
   Cancel ministry creation (owner, pastor, or admin)
----------------------------------------------------------------- */
exports.cancelMinistryCreation = onCall(async (request) => {
  const auth = requireAuth(request);
  const uid = auth.uid;

  const requestId = s(request.data?.requestId);
  if (!requestId) throw HttpsError("invalid-argument", "requestId required.");

  const reqRef = db.collection("ministry_creation_requests").doc(requestId);
  const snap = await reqRef.get();
  if (!snap.exists) throw HttpsError("not-found", "Request not found.");

  const r = snap.data();
  if (r.status !== "pending") return { ok: true, info: "Already processed." };

  const roles = await getUserRoles(uid);
  const isOwner = s(r.requestedByUid) === uid;
  const isPastorOrAdmin = hasRole(roles, "pastor") || hasRole(roles, "admin");
  if (!isOwner && !isPastorOrAdmin) {
    throw HttpsError("permission-denied", "Only the requester or a pastor/admin can cancel.");
  }

  await reqRef.delete();

  await writeNotification({
    toRole: "pastor",
    type: "ministry_request_cancelled",
    title: "Ministry request cancelled",
    body: `"${s(r.name)}" was cancelled by ${isOwner ? 'the requester' : 'a pastor/admin'}.`,
    route: "/pastor-approvals",
    requestId,
    ministryName: s(r.name),
  });

  return { ok: true, requestId };
});

/* --------------------------------------------------
   Nightly cleanup (placeholder)
-------------------------------------------------- */
exports.cleanupOldInboxEvents = onSchedule(
  {
    schedule: "30 3 * * *",
    timeZone: "Europe/London",
    region: "europe-west2",
    memory: "256MiB",
  },
  async () => {
    // TODO if you want to prune old inbox items
  }
);
