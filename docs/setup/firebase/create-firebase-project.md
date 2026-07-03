# Create a Firebase project

You need your **own** Firebase project. micaGO never creates one for you and does
not operate any shared/cloud project.

1. Go to the [Firebase Console](https://console.firebase.google.com).
2. **Add project** → give it a name (e.g. `micago-personal`). Google Analytics is
   optional and not required by micaGO.
3. Once created, note the **Project ID** (Console → Project settings → General).
   micaGO can infer this from the service account, so setting it is optional.

That's all that's required at the project level. Next:

- [Add Android / FCM](android-fcm.md) so your Android client can register for push.
- [Create a service account](service-account.md) for the micaGO server to send push.

> No billing is required for standard FCM usage. micaGO does not enable any paid
> Firebase features. Firestore (optional, for URL sync) has a free tier that is
> far beyond what a single small document needs.
