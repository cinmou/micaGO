package com.micago.conversations;

import android.content.Context;
import android.app.NotificationManager;
import androidx.core.app.NotificationCompat;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import androidx.core.app.Person;
import androidx.core.content.LocusIdCompat;
import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry.NewIntentListener;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;

/** Platform conversation metadata only; transport and actions stay in Dart. */
public final class ConversationsPlugin implements FlutterPlugin, ActivityAware, NewIntentListener {
    private static final String ACTION = "com.micago.OPEN_CONVERSATION";
    private static final String PAYLOAD = "micago.conversation.payload";
    private Context context;
    private MethodChannel channel;
    private ActivityPluginBinding activityBinding;
    private String initial;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "micago/conversations");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "publish":
                        if (Build.VERSION.SDK_INT < 25) { result.success(null); break; }
                        String chat = call.argument("chatGuid");
                        String device = call.argument("deviceId");
                        String title = call.argument("title");
                        String payload = call.argument("payload");
                        if (chat == null || device == null || title == null || payload == null) {
                            result.success(null); break;
                        }
                        MessageDigest digest = MessageDigest.getInstance("SHA-256");
                        byte[] hash = digest.digest((device + "\u001f" + chat).getBytes(StandardCharsets.UTF_8));
                        StringBuilder key = new StringBuilder("conversation_");
                        for (byte b : hash) key.append(String.format("%02x", b & 255));
                        String id = key.toString();
                        Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
                        if (intent == null) { result.success(null); break; }
                        intent.setAction(ACTION).putExtra(PAYLOAD, payload);
                        IconCompat icon = IconCompat.createWithResource(context, context.getApplicationInfo().icon);
                        String avatarPath = call.argument("avatarPath");
                        IconCompat photo = iconFromFile(avatarPath);
                        if (photo != null) icon = photo;
                        String personName = call.argument("personName");
                        String personKey = call.argument("personKey");
                        IconCompat personIcon = iconFromFile(call.argument("personAvatarPath"));
                        ShortcutInfoCompat shortcut = new ShortcutInfoCompat.Builder(context, id)
                            .setShortLabel(title.isEmpty() ? "micaGO" : title)
                            .setIntent(intent).setIcon(icon).setLongLived(true)
                            .setPerson(new Person.Builder().setName(personName == null ? title : personName).setKey(personKey == null ? chat : personKey).setIcon(personIcon).build())
                            .setLocusId(new LocusIdCompat(id)).build();
                        result.success(ShortcutManagerCompat.pushDynamicShortcut(context, shortcut) ? id : null);
                        break;
                    case "cancelThrough":
                        if (Build.VERSION.SDK_INT >= 24) {
                            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
                            Number notificationId = call.argument("id");
                            Number through = call.argument("through");
                            if (notificationId != null && through != null) {
                                for (android.service.notification.StatusBarNotification posted : manager.getActiveNotifications()) {
                                    if (posted.getId() != notificationId.intValue()) continue;
                                    NotificationCompat.MessagingStyle style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(posted.getNotification());
                                    if (style == null || style.getMessages().isEmpty()) continue;
                                    long latest = 0;
                                    for (NotificationCompat.MessagingStyle.Message message : style.getMessages()) latest = Math.max(latest, message.getTimestamp());
                                    if (latest <= through.longValue()) manager.cancel(notificationId.intValue());
                                }
                            }
                        }
                        result.success(null); break;
                    case "clear":
                        ArrayList<String> ids = new ArrayList<>();
                        for (ShortcutInfoCompat item : ShortcutManagerCompat.getShortcuts(context,
                                ShortcutManagerCompat.FLAG_MATCH_DYNAMIC | ShortcutManagerCompat.FLAG_MATCH_CACHED | ShortcutManagerCompat.FLAG_MATCH_PINNED)) {
                            if (item.getId().startsWith("conversation_") || item.getId().startsWith("share_")) ids.add(item.getId());
                        }
                        ShortcutManagerCompat.removeLongLivedShortcuts(context, ids);
                        ShortcutManagerCompat.disableShortcuts(context, ids, "Connect to micaGO to open this conversation.");
                        result.success(null); break;
                    case "takeInitial": result.success(initial); initial = null; break;
                    default: result.notImplemented();
                }
            } catch (Exception failure) {
                // Shortcut limits or bad photos must never prevent a notification.
                result.error("conversation_unavailable", "Conversation metadata is unavailable.", null);
            }
        });
    }
    private static IconCompat iconFromFile(String path) {
        if (path == null) return null;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(path, options);
        options.inSampleSize = Math.max(1, Math.max(options.outWidth, options.outHeight) / 256);
        options.inJustDecodeBounds = false;
        Bitmap bitmap = BitmapFactory.decodeFile(path, options);
        return bitmap == null ? null : IconCompat.createWithAdaptiveBitmap(bitmap);
    }
    @Override public boolean onNewIntent(Intent intent) {
        if (!ACTION.equals(intent.getAction())) return false;
        String payload = intent.getStringExtra(PAYLOAD);
        if (payload != null) channel.invokeMethod("open", payload);
        intent.removeExtra(PAYLOAD);
        return true;
    }
    @Override public void onAttachedToActivity(ActivityPluginBinding binding) {
        activityBinding = binding;
        Intent intent = binding.getActivity().getIntent();
        if (ACTION.equals(intent.getAction())) {
            initial = intent.getStringExtra(PAYLOAD);
            intent.removeExtra(PAYLOAD);
        }
        binding.addOnNewIntentListener(this);
    }
    @Override public void onDetachedFromActivity() {
        if (activityBinding != null) activityBinding.removeOnNewIntentListener(this);
        activityBinding = null;
    }
    @Override public void onDetachedFromActivityForConfigChanges() { onDetachedFromActivity(); }
    @Override public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) { onAttachedToActivity(binding); }
    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) { channel.setMethodCallHandler(null); }
}
