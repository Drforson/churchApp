import * as functions from "firebase-functions";
import * as admin from "firebase-admin";

admin.initializeApp();
const db = admin.firestore();
const messaging = admin.messaging();

// Utility: safe string
const s = (v: unknown) => (typeof v === "string" ? v : "");

// Where to write bell items (kept within your rules: /inbox/{uid}/events/{eventId})
function inboxEventRef(uid: string) {
  return db.collection("inbox").doc(uid).collection("events").doc();
}

/**
 * onCreate join_requests/{requestId}
 * Notifies:
 *  - all admins (users.roles array-contains 'admin')
 *  - all leaders of the requested ministry (users.leadershipMinistries array-contains ministryName)
 */
export const onJoinRequestCreate = functions
  .region("europe-west2") // pick your region
  .firestore.document("join_requests/{requestId}")
  .onCreate(async (snap, context) => {
    const jr = snap.data();
    if (!jr) return;

    const requestId = context.params.requestId as string;
    const ministryId = s(jr.ministryId);
    const memberId = s(jr.memberId);
    const requestedAt = jr.requestedAt?.toDate?.() ?? new Date();

    if (!ministryId || !memberId) {
      console.warn("join_requests create missing ministryId or memberId", jr);
      return;
    }

    // Resolve ministry name
    const minDoc = await db.collection("ministries").doc(ministryId).get();
    const ministryName = s(minDoc.get("name"));

    // Find admins
    const adminsQ = await db
      .collection("users")
      .where("roles", "array-contains", "admin")
      .get();

    // Find leaders of this ministry (your schema stores NAMES in leadershipMinistries)
    const leadersQ = ministryName
      ? await db
          .collection("users")
          .where("leadershipMinistries", "array-contains", ministryName)
          .get()
      : { docs: [] as FirebaseFirestore.QueryDocumentSnapshot[] };

    // Merge distinct recipients
    const recipients = new Map<string, FirebaseFirestore.DocumentData>();
    adminsQ.docs.forEach((d) => recipients.set(d.id, d.data()));
    leadersQ.docs.forEach((d) => recipients.set(d.id, d.data()));

    if (recipients.size === 0) {
      return;
    }

    // Prepare inbox event payload
    const eventPayload = {
      type: "join_request_created",
      joinRequestId: requestId,
      ministryId,
      ministryName,
      memberId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      title: "New join request",
      body: ministryName
        ? `A member requested to join: ${ministryName}`
        : `A member requested to join ministry ${ministryId}`,
    };

    // Batch write inbox events
    const batch = db.batch();
    const fcmTokens: string[] = [];

    recipients.forEach((uData, uid) => {
      const ref = inboxEventRef(uid);
      batch.set(ref, eventPayload, { merge: true });

      const token = s(uData?.fcmToken);
      if (token) fcmTokens.push(token);
    });

    await batch.commit();

    // Optional: Push a compact FCM notification
    if (fcmTokens.length) {
      try {
        await messaging.sendEachForMulticast({
          tokens: fcmTokens,
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

/**
 * Optional: onUpdate join_requests/{requestId}
 * When status changes from 'pending' -> 'approved'/'rejected', notify:
 *  - the requesting member's linked user (via users where memberId == jr.memberId)
 *  - (optionally) leaders/admins as an audit item
 */
export const onJoinRequestStatusChange = functions
  .region("europe-west2")
  .firestore.document("join_requests/{requestId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    if (!before || !after) return;

    const statusBefore = s(before.status || "pending");
    const statusAfter = s(after.status || "pending");
    if (statusBefore === statusAfter) return;

    const requestId = context.params.requestId as string;
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

    const payload = {
      type: "join_request_status",
      joinRequestId: requestId,
      ministryId,
      ministryName,
      memberId,
      status: statusAfter,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      title:
        statusAfter === "approved"
          ? "Join request approved"
          : statusAfter === "rejected"
          ? "Join request rejected"
          : `Join request ${statusAfter}`,
      body:
        statusAfter === "approved"
          ? (ministryName
              ? `Your request to join ${ministryName} was approved`
              : `Your join request was approved`)
          : (ministryName
              ? `Your request to join ${ministryName} was ${statusAfter}`
              : `Your join request was ${statusAfter}`),
    };

    await inboxEventRef(uid).set(payload);

    if (fcmToken) {
      try {
        await messaging.send({
          token: fcmToken,
          notification: {
            title: payload.title,
            body: payload.body,
          },
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
