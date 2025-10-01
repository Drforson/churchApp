// functions/index.js

// Import Firebase Functions (v2 style) and Admin SDK
const { onCall } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// Initialize Firebase Admin
initializeApp();

// ✅ Simple test function (use this to verify deployment first)
exports.ping = onCall(() => {
  return { ok: true, pong: true };
});

// ✅ Promote current signed-in user to Admin role
const ALLOWLIST_EMAILS = [
  "forsonalfred21@gmail.com",
   "carlos@gmail.com",
   "admin@gmail.com",// <-- replace with your dev email
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

  const allowed = isEmulator || ALLOWLIST_EMAILS.includes(email);
  if (!allowed) {
    const err = new Error("permission-denied");
    err.code = "permission-denied";
    throw err;
  }

  const uid = auth.uid;
  const db = getFirestore();

  // Get user document
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    const err = new Error("failed-precondition: user doc not found");
    err.code = "failed-precondition";
    throw err;
  }

  const userData = userSnap.data() || {};
  const memberId = userData.memberId || null;

  // Add 'admin' role to the user doc
  await userRef.set(
    { roles: FieldValue.arrayUnion("admin") },
    { merge: true }
  );

  // Also update the linked member doc (if any)
  if (memberId) {
    await db.collection("members").doc(memberId).set(
      { roles: FieldValue.arrayUnion("admin") },
      { merge: true }
    );
  }

  return { ok: true, uid, memberId };
});
