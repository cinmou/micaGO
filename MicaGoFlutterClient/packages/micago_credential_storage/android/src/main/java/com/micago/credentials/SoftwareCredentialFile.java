package com.micago.credentials;

import android.util.AtomicFile;
import com.google.crypto.tink.Aead;
import com.google.crypto.tink.InsecureSecretKeyAccess;
import com.google.crypto.tink.KeysetHandle;
import com.google.crypto.tink.RegistryConfiguration;
import com.google.crypto.tink.TinkProtoKeysetFormat;
import com.google.crypto.tink.aead.PredefinedAeadParameters;
import com.google.crypto.tink.config.TinkConfig;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;


/** Tink ciphertext with a local software keyset, atomically replaced as one file. */
final class SoftwareCredentialFile {
    private static final int FORMAT = 1;
    private static final int MAX_BYTES = 1024 * 1024;
    private static final byte[] AAD = "micago.connection_profile.software.v1".getBytes(StandardCharsets.UTF_8);
    static void write(AtomicFile file, String value) throws Exception {
        byte[] plaintext = value.getBytes(StandardCharsets.UTF_8);
        if (plaintext.length > MAX_BYTES) throw new IllegalArgumentException();
        TinkConfig.register();
        KeysetHandle handle = KeysetHandle.generateNew(PredefinedAeadParameters.AES256_GCM);
        Aead aead = handle.getPrimitive(RegistryConfiguration.get(), Aead.class);
        byte[] ciphertext;
        try { ciphertext = aead.encrypt(plaintext, AAD); }
        finally { Arrays.fill(plaintext, (byte) 0); }
        byte[] keyset = TinkProtoKeysetFormat.serializeKeyset(handle, InsecureSecretKeyAccess.get());
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream output = new DataOutputStream(bytes)) {
            output.writeInt(FORMAT);
            output.writeInt(keyset.length); output.write(keyset);
            output.writeInt(ciphertext.length); output.write(ciphertext);
        } finally { Arrays.fill(keyset, (byte) 0); }
        FileOutputStream stream = file.startWrite();
        try {
            stream.write(bytes.toByteArray());
            file.finishWrite(stream);
        } catch (Exception failure) {
            file.failWrite(stream); throw failure;
        }
    }

    static String read(AtomicFile file) throws Exception {
        if (!file.getBaseFile().exists() && !new File(file.getBaseFile() + ".bak").exists()) return null;
        TinkConfig.register();
        try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(file.readFully()))) {
            if (input.readInt() != FORMAT) throw new IllegalArgumentException();
            byte[] keyset = readField(input);
            KeysetHandle handle;
            try { handle = TinkProtoKeysetFormat.parseKeyset(keyset, InsecureSecretKeyAccess.get()); }
            finally { Arrays.fill(keyset, (byte) 0); }
            byte[] ciphertext = readField(input);
            if (input.available() != 0) throw new IllegalArgumentException();
            byte[] plaintext = handle.getPrimitive(RegistryConfiguration.get(), Aead.class).decrypt(ciphertext, AAD);
            try { return new String(plaintext, StandardCharsets.UTF_8); }
            finally { Arrays.fill(plaintext, (byte) 0); }
        }
    }

    private static byte[] readField(DataInputStream input) throws Exception {
        int size = input.readInt();
        if (size <= 0 || size > MAX_BYTES + 1024 || size > input.available()) throw new IllegalArgumentException();
        byte[] value = new byte[size]; input.readFully(value); return value;
    }

}
