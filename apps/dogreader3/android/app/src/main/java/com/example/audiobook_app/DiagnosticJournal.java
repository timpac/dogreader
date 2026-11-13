package com.example.audiobook_app;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Single-writer journal. Does no scheduling and accepts only pre-sanitized data. */
public final class DiagnosticJournal {
    private final File current;
    private final File previous;
    private final int maxBytes;

    public DiagnosticJournal(File directory, int maxBytes) {
        this.current = new File(directory, "native.jsonl");
        this.previous = new File(directory, "native.previous.jsonl");
        this.maxBytes = maxBytes;
    }

    public void append(String line) throws IOException {
        byte[] bytes = (line + "\n").getBytes(StandardCharsets.UTF_8);
        if (bytes.length > maxBytes) throw new IOException("record_too_large");
        File directory = current.getParentFile();
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("directory_unavailable");
        if (current.exists() && current.length() + bytes.length > maxBytes) {
            if (previous.exists() && !previous.delete()) throw new IOException("rotation_delete_failed");
            if (!current.renameTo(previous)) throw new IOException("rotation_rename_failed");
        }
        try (FileOutputStream stream = new FileOutputStream(current, true)) {
            stream.write(bytes);
        }
    }

    public String snapshot() throws IOException {
        StringBuilder result = new StringBuilder();
        for (File file : new File[] {previous, current}) {
            if (!file.exists()) continue;
            result.append("\n--- ").append(file.getName()).append(" ---\n");
            try (FileInputStream stream = new FileInputStream(file);
                 ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096];
                int remaining = maxBytes;
                while (remaining > 0) {
                    int count = stream.read(buffer, 0, Math.min(buffer.length, remaining));
                    if (count == -1) break;
                    bytes.write(buffer, 0, count);
                    remaining -= count;
                }
                result.append(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
            }
        }
        return result.toString();
    }
}
