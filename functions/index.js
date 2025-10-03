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
// (FCM is required lazily where used to avoid load hiccups)

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
// Helpers
// ----------------------------------------
const s = (v) => (typeof v === "string" ? v : "");
const inboxEventRef = (uid) => db.collection("inbox").doc(uid).collection("events").doc();
const ttlDate = (days) => new Date(Date.now() + days * 24 * 60 * 60 * 1000);

// ----------------------------------------
// Canary callable (health check)
// ----------------------------------------
exports.ping = onCall(() => ({ ok: true, pong: true }));

// ----------------------------------------
// Promote current signed-in user to Admin
// ----------------------------------------
const ALLOWLIST_EMAILS = [
  "forsonalfred21@gmail.com",
  "carlos@gmail.com",
  "admin@gmail.com" // update to your real dev/admin emails
];

exports.promoteMeToAdmin = onCall(async (request) => {
  const auth = request.auth;
  if (!auth) {
    const err = new Error("unauthenticated");
    err.code = "unauthenticated";
    throw err;
  }

  const email = auth.token.email || "";
  const isEmulator =
    !!process.env.FIREBASE_AUTH_EMULATOR_HOST ||
    !!process.env.FIRESTORE_EMULATOR_HOST;

  if (!isEmulator && !ALLOWLIST_EMAILS.includes(email)) {
    const err = new Error("permission-denied");
    err.code = "permission-denied";
    throw err;
  }

  const uid = auth.uid;
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    const err = new Error("failed-precondition: user doc not found");
    err.code = "failed-precondition";
    throw err;
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

// --------------------------------------------------
// 🔔 Join Requests → Inbox notifications
// --------------------------------------------------

// 1) onCreate join_requests: notify admins + leaders of that ministry
exports.onJoinRequestCreate = onDocumentCreated("join_requests/{requestId}", async (event) => {
  const snap = event.data;
  if (!snap) return;

  const jr = snap.data();
  const requestId = event.params.requestId;
  const ministryId = s(jr.ministryId);
  const memberId = s(jr.memberId);

  if (!ministryId || !memberId) {
    console.warn("join_requests create missing ministryId or memberId", jr);
    return;
  }

  // Resolve ministry name (leaders store NAMES in users.leadershipMinistries)
  const minDoc = await db.collection("ministries").doc(ministryId).get();
  const ministryName = s(minDoc.get("name"));

  // Find admins
  const adminsQ = await db
    .collection("users")
    .where("roles", "array-contains", "admin")
    .get();

  // Find leaders for this ministry by NAME
  const leadersQ = ministryName
    ? await db
        .collection("users")
        .where("leadershipMinistries", "array-contains", ministryName)
        .get()
    : { docs: [] };

  // Merge recipients unique by uid
  const recipients = new Map();
  adminsQ.docs.forEach((d) => recipients.set(d.id, d.data()));
  leadersQ.docs.forEach((d) => recipients.set(d.id, d.data()));

  if (recipients.size === 0) {
    console.log("No recipients for join request", { ministryId, ministryName });
    return;
  }

  const eventPayload = {
    type: "join_request_created",
    joinRequestId: requestId,
    ministryId,
    ministryName,
    memberId,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: ttlDate(60), // optional TTL field
    title: "New join request",
    body: ministryName
      ? `A member requested to join: ${ministryName}`
      : `A member requested to join a ministry`,
  };

  // Write inbox events + collect FCM tokens
  const batch = db.batch();
  const tokens = [];

  recipients.forEach((uData, uid) => {
    batch.set(inboxEventRef(uid), eventPayload, { merge: true });
    const token = s(uData?.fcmToken);
    if (token) tokens.push(token);
  });

  await batch.commit();

  // Optional FCM push (lazy require)
  if (tokens.length) {
    try {
      const { getMessaging } = require("firebase-admin/messaging");
      const messaging = getMessaging();
      await messaging.sendEachForMulticast({
        tokens,
        notification: {
          title: "New join request",
          body: ministryName
            ? `A member requested to join ${ministryName}`
            : `A member requested to join a ministry`,
        },
        data: {
          type: "join_request_created",
          joinRequestId: requestId,
          ministryId,
          ministryName,
        },
      });
    } catch (err) {
      console.warn("FCM send error", err);
    }
  }
});

// 2) onUpdate join_requests: if status changed, notify the requester
exports.onJoinRequestStatusChange = onDocumentUpdated("join_requests/{requestId}", async (event) => {
  const before = event.data.before.data();
  const after = event.data.after.data();
  if (!before || !after) return;

  const statusBefore = s(before.status || "pending");
  const statusAfter = s(after.status || "pending");
  if (statusBefore === statusAfter) return;

  const requestId = event.params.requestId;
  const ministryId = s(after.ministryId);
  const memberId = s(after.memberId);

  // Resolve ministry name
  const minDoc = await db.collection("ministries").doc(ministryId).get();
  const ministryName = s(minDoc.get("name"));

  // Find the user linked to this memberId
  const userQ = await db
    .collection("users")
    .where("memberId", "==", memberId)
    .limit(1)
    .get();

  if (userQ.empty) return;

  const userDoc = userQ.docs[0];
  const uid = userDoc.id;
  const fcmToken = s(userDoc.get("fcmToken"));

  const title =
    statusAfter === "approved"
      ? "Join request approved"
      : statusAfter === "rejected"
      ? "Join request rejected"
      : `Join request ${statusAfter}`;

  const body =
    statusAfter === "approved"
      ? (ministryName
          ? `Your request to join ${ministryName} was approved`
          : `Your join request was approved`)
      : (ministryName
          ? `Your request to join ${ministryName} was ${statusAfter}`
          : `Your join request was ${statusAfter}`);

  const payload = {
    type: "join_request_status",
    joinRequestId: requestId,
    ministryId,
    ministryName,
    memberId,
    status: statusAfter,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: ttlDate(60),
    title,
    body,
  };

  await inboxEventRef(uid).set(payload);

  if (fcmToken) {
    try {
      const { getMessaging } = require("firebase-admin/messaging");
      const messaging = getMessaging();
      await messaging.send({
        token: fcmToken,
        notification: { title, body },
        data: {
          type: "join_request_status",
          joinRequestId: requestId,
          ministryId,
          ministryName,
          status: statusAfter,
        },
      });
    } catch (err) {
      console.warn("FCM single send error", err);
    }
  }
});

// --------------------------------------------------
// 🧹 Nightly cleanup: delete inbox events older than 60 days
// (Requires Blaze for scheduled functions. Comment out if on Spark.)
// --------------------------------------------------
exports.cleanupOldInboxEvents = onSchedule(
  {
    schedule: "30 3 * * *",    // 03:30 daily
    timeZone: "Europe/London", // your TZ
    region: "europe-west2",
    memory: "256MiB",
  },
  async () => {
    const cutoff = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000);
    const batchSize = 500;
    let totalDeleted = 0;

    while (true) {
      const snap = await db
        .collectionGroup("events")
        .where("createdAt", "<", cutoff)
        .limit(batchSize)
        .get();

      if (snap.empty) break;

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();

      totalDeleted += snap.size;
      await new Promise((r) => setTimeout(r, 250));
    }

    console.log(
      `[cleanupOldInboxEvents] Deleted ${totalDeleted} old inbox events (cutoff=${cutoff.toISOString()})`
    );
  }
);
