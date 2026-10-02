package com.micago.credentials;

import android.app.Instrumentation;
import android.os.Bundle;
import android.util.AtomicFile;
import java.io.File;
import java.nio.charset.StandardCharsets;

/** Exercises the actual Tink/provider/file behavior on engineering ROMs. */
public final class CredentialStorageInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        AtomicFile file = new AtomicFile(new File(getTargetContext().getNoBackupFilesDir(), "credential-test"));
        Bundle status = new Bundle();
        status.putString("class", getClass().getName());
        status.putString("test", "softwareCredentialPersistenceAndTamper");
        status.putInt("numtests", 1); status.putInt("current", 1);
        sendStatus(1, status);
        try {
            String credential = "non-production-instrumentation-fixture";
            SoftwareCredentialFile.write(file, credential);
            if (!credential.equals(SoftwareCredentialFile.read(new AtomicFile(file.getBaseFile())))) throw new AssertionError("restart read");
            String bytes = new String(file.readFully(), StandardCharsets.ISO_8859_1);
            if (bytes.contains(credential)) throw new AssertionError("plaintext on disk");
            byte[] tampered = file.readFully(); tampered[tampered.length - 1] ^= 1;
            java.nio.file.Files.write(file.getBaseFile().toPath(), tampered);
            boolean rejected = false;
            try { SoftwareCredentialFile.read(file); } catch (Exception expected) { rejected = true; }
            if (!rejected) throw new AssertionError("tamper accepted");
            SoftwareCredentialFile.write(file, "replacement");
            if (!"replacement".equals(SoftwareCredentialFile.read(file))) throw new AssertionError("replacement");
            file.delete();
            if (SoftwareCredentialFile.read(file) != null) throw new AssertionError("delete");
            status.putString("stream", "PASS software storage, restart read, ciphertext, tamper rejection, replacement and delete\n");
            sendStatus(0, status);
            result.putString("stream", "OK (1 test)\n");
            finish(-1, result);
        } catch (Throwable failure) {
            status.putString("stack", failure.toString()); sendStatus(-2, status);
            result.putString("stream", "FAIL software credential storage\n"); finish(0, result);
        } finally { file.delete(); }
    }
}
