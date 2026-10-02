package com.micago.credentials;

import android.content.Context;
import android.util.AtomicFile;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;
import java.io.File;

/** Software encryption only: root can read the keyset alongside the ciphertext. */
public final class CredentialStoragePlugin implements FlutterPlugin {
    private static final Object LOCK = new Object();
    private MethodChannel channel;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        Context context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "micago/software_credentials",
            StandardMethodCodec.INSTANCE, binding.getBinaryMessenger().makeBackgroundTaskQueue());
        channel.setMethodCallHandler((call, result) -> {
            synchronized (LOCK) {
                try {
                    AtomicFile file = new AtomicFile(new File(context.getNoBackupFilesDir(), "micago_credentials_v1"));
                    switch (call.method) {
                        case "read": result.success(SoftwareCredentialFile.read(file)); break;
                        case "write":
                            if (!(call.arguments instanceof String)) throw new IllegalArgumentException();
                            SoftwareCredentialFile.write(file, (String) call.arguments);
                            result.success(null); break;
                        case "delete": file.delete(); result.success(null); break;
                        case "probe":
                            AtomicFile probe = new AtomicFile(new File(context.getNoBackupFilesDir(), "micago_credentials_probe"));
                            try {
                                SoftwareCredentialFile.write(probe, "storage-probe");
                                if (!"storage-probe".equals(SoftwareCredentialFile.read(probe))) throw new IllegalStateException();
                            } finally { probe.delete(); }
                            result.success(null); break;
                        default: result.notImplemented();
                    }
                } catch (Exception failure) {
                    // Platform exception details must never contain credential/key bytes.
                    result.error("credential_storage_failed", "Credential storage is unavailable.", null);
                }
            }
        });
    }

    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }
}
