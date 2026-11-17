package com.example.audiobook_app;

import android.content.Context;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;
import org.json.JSONTokener;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Runs the shipped extraction script in a real WebView against offline fixtures. */
@RunWith(AndroidJUnit4.class)
public class FreePressExtractionTest {
    private JSONObject capture(String body) throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        String script;
        try (java.io.InputStream stream = context.getAssets().open("freepress_extract.js")) {
            script = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        }
        String captureScript = script;
        CountDownLatch finished = new CountDownLatch(1);
        AtomicReference<String> answer = new AtomicReference<>();
        AtomicReference<WebView> view = new AtomicReference<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            WebView browser = new WebView(context);
            view.set(browser);
            browser.getSettings().setJavaScriptEnabled(true);
            browser.setWebViewClient(new WebViewClient() {
                @Override public void onPageFinished(WebView web, String url) {
                    web.evaluateJavascript(captureScript, raw -> { answer.set(raw); finished.countDown(); });
                }
            });
            browser.layout(0, 0, 1080, 1920);
            browser.loadDataWithBaseURL("https://www.thefp.com/p/offline-fixture", "<!doctype html><html><body>" + body + "</body></html>", "text/html", "UTF-8", null);
        });
        try {
            assertTrue("Offline extraction callback", finished.await(20, TimeUnit.SECONDS));
            Object payload = new JSONTokener(answer.get()).nextValue();
            assertTrue("Article-only JSON string", payload instanceof String);
            return new JSONObject((String) payload);
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> view.get().destroy());
        }
    }

    private String paragraph() {
        return "Ordinary visible article words about journalism and public institutions. ".repeat(20);
    }

    @Test public void renderedTextExcludesHiddenStateFormsAndNavigation() throws Exception {
        JSONObject result = capture("<h1>A subscriber essay</h1><nav><p>Navigation secret</p></nav>" +
            "<article><div class='body markup'><h2>First heading</h2><p>Inline pre<em>fix</em> and full <strong>words</strong>. " + paragraph() +
            "<span style='display:none'>Hidden secret</span><span style='opacity:0'>Transparent secret</span></p>" +
            "<blockquote><p>A quoted paragraph.</p></blockquote><ul><li>A list item.</li></ul>" +
            "<form><p>Credential secret</p><input value='password secret'></form>" +
            "<script>window.sessionToken='Script secret';</script><hr><p>The real ending.</p></div></article>");
        assertFalse(result.has("error"));
        String json = result.toString();
        for (String secret : new String[]{"Navigation secret", "Hidden secret", "Transparent secret", "Credential secret", "password secret", "Script secret"}) assertFalse(secret, json.contains(secret));
        assertEquals("A subscriber essay", result.getString("title"));
        assertEquals(6, result.getJSONArray("blocks").length());
        assertTrue(result.getJSONArray("blocks").getJSONObject(1).getString("text").startsWith("Inline prefix and full words."));
        assertEquals("quote", result.getJSONArray("blocks").getJSONObject(2).getString("kind"));
        assertEquals("The real ending.", result.getJSONArray("blocks").getJSONObject(5).getString("text"));
    }

    @Test public void visiblePaywallDoesNotImportHiddenSubscriberText() throws Exception {
        JSONObject result = capture("<h1>Restricted essay</h1><article><div class='paywall'>This post is for paid subscribers</div>" +
            "<div class='body markup' style='display:none'><p>" + paragraph() + " Subscriber secret</p></div></article>");
        assertEquals("PAYWALL", result.getString("error"));
        assertFalse(result.toString().contains("Subscriber secret"));
    }

    @Test public void loginShellAndOversizedBodyAreRejected() throws Exception {
        assertEquals("NO_ARTICLE", capture("<h1>Sign in</h1><form><p>Email and password</p></form>").getString("error"));
        assertEquals("TOO_LARGE", capture("<h1>Very long essay</h1><article><p>" + "visible ".repeat(26000) + "</p></article>").getString("error"));
    }

    @Test public void onlyPublicArticlePathsCanLeaveTheBrowser() {
        assertEquals("https://www.thefp.com/p/essay", FreePressLoginActivity.Companion.articleUrl("https://thefp.com/p/essay/?token=secret#session"));
        for (String url : new String[]{"https://substack.com/sign-in?token=secret", "https://www.thefp.com/account/login?token=secret", "https://www.thefp.com/p/essay/extra", "https://www.thefp.com.evil.test/p/essay"}) assertNull(FreePressLoginActivity.Companion.articleUrl(url));
    }
}
