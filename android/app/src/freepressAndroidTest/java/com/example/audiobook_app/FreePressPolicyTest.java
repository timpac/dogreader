package com.example.audiobook_app;

import android.content.Context;
import android.content.pm.ActivityInfo;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** No network requests, real accounts, user content or login cookies. */
@RunWith(AndroidJUnit4.class)
public class FreePressPolicyTest {
    @Test public void navigationAcceptsOnlyExpectedSecureOrigins() {
        for (String url : new String[] {
            "https://www.thefp.com/p/test", "https://thefp.com/",
            "https://substack.com/sign-in?redirect=https%3A%2F%2Fwww.thefp.com",
            "https://www.substack.com/", "https://www.thefp.com:443/"
        }) assertTrue(url, FreePressLoginActivity.Companion.allowedUrl(url));
        for (String url : new String[] {
            "http://www.thefp.com", "https://www.thefp.com.evil.test/",
            "https://evil.test/?host=www.thefp.com", "https://thefp.com@evil.test/",
            "https://name@www.thefp.com/", "https://www.thefp.com:8443/",
            "file:///data/data/test", "content://test", "javascript:alert(1)",
            "intent://test", "https://accounts.google.com/", "https://elsewhere.substack.com/"
        }) assertFalse(url, FreePressLoginActivity.Companion.allowedUrl(url));
    }

    @Test public void embeddedActivityIsPrivateAndHasBackupExclusions() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        assertEquals("com.example.audiobook_app.experimental", context.getPackageName());
        ActivityInfo activity = context.getPackageManager().getActivityInfo(
            new android.content.ComponentName(context, FreePressLoginActivity.class), 0);
        assertFalse(activity.exported);
        assertTrue((activity.flags & ActivityInfo.FLAG_EXCLUDE_FROM_RECENTS) != 0);
        android.content.res.XmlResourceParser rules = context.getResources().getXml(
            context.getResources().getIdentifier("freepress_backup_rules", "xml", context.getPackageName()));
        int exclusions = 0;
        while (rules.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            if (rules.getEventType() == org.xmlpull.v1.XmlPullParser.START_TAG && "exclude".equals(rules.getName())) {
                assertEquals("root", rules.getAttributeValue(null, "domain"));
                assertTrue(rules.getAttributeValue(null, "path").startsWith("app_webview"));
                exclusions++;
            }
        }
        assertEquals(2, exclusions);
        rules.close();
    }
}
