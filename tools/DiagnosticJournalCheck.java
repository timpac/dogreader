import com.example.audiobook_app.DiagnosticJournal;
import java.io.File;
import java.nio.file.Files;

/** Focused JVM check; no Android runtime or dependency download required. */
public final class DiagnosticJournalCheck {
    public static void main(String[] args) throws Exception {
        File root = Files.createTempDirectory("dogreader-journal-").toFile();
        try {
            DiagnosticJournal journal = new DiagnosticJournal(root, 64);
            for (int i = 0; i < 40; i++) journal.append("{\"event\":\"state\",\"id\":" + i + "}");
            DiagnosticJournal reopened = new DiagnosticJournal(root, 64);
            String text = reopened.snapshot();
            if (!text.contains("\"id\":39") || text.contains("\"id\":0}")) throw new AssertionError(text);
            for (File file : root.listFiles()) {
                if (file.length() > 64) throw new AssertionError("unbounded journal");
            }
            try {
                journal.append("x".repeat(100));
                throw new AssertionError("oversize record accepted");
            } catch (java.io.IOException expected) { }
            File blocker = new File(root, "blocked");
            Files.writeString(blocker.toPath(), "file");
            try {
                new DiagnosticJournal(blocker, 64).append("event");
                throw new AssertionError("invalid storage accepted");
            } catch (java.io.IOException expected) { }
            System.out.println("Diagnostic journal rotation, restart, bounds and I/O checks passed");
        } finally {
            for (File file : root.listFiles()) file.delete();
            root.delete();
        }
    }
}
