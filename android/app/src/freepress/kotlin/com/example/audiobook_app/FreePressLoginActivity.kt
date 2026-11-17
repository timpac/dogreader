package com.example.audiobook_app

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import org.json.JSONObject
import org.json.JSONTokener
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/** Device-local publisher session. Only an explicit article capture can return text. */
class FreePressLoginActivity : Activity() {
    private lateinit var browser: WebView
    private lateinit var status: TextView
    private lateinit var importButton: Button
    private var pageLoading = false
    private var capturing = false

    companion object {
        private var profileInitialized = false
        const val HOME = "https://www.thefp.com/"

        fun articleUrl(value: String): String? = try {
            val uri = Uri.parse(value)
            if (value.length <= 8192 && allowedUrl(value) && uri.host?.lowercase() in setOf("thefp.com", "www.thefp.com") &&
                Regex("^/(?:p|cp)/[A-Za-z0-9_-]+/?$").matches(uri.path ?: "")) {
                "https://www.thefp.com${uri.path!!.trimEnd('/')}"
            } else null
        } catch (_: Exception) { null }

        fun allowedUrl(value: String): Boolean = try {
            val uri = Uri.parse(value)
            uri.scheme == "https" && uri.userInfo == null &&
                (uri.port == -1 || uri.port == 443) &&
                uri.host?.lowercase() in setOf("thefp.com", "www.thefp.com", "substack.com", "www.substack.com")
        } catch (_: Exception) { false }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(null) // Never restore sign-in URLs or form contents from a Bundle.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (!profileInitialized) {
            if (Build.VERSION.SDK_INT >= 28) WebView.setDataDirectorySuffix("freepress")
            WebView.setWebContentsDebuggingEnabled(false) // Also in signed debug APKs.
            profileInitialized = true
        }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(12, 12, 12, 12)
            if (Build.VERSION.SDK_INT >= 26) importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        status = TextView(this).apply {
            text = "Sign in here if needed. Open an article, then tap Save and read to use DogReader's offline reader. Chrome login is separate."
        }
        layout.addView(status)
        val toolbar = LinearLayout(this)
        fun button(label: String, action: () -> Unit) = Button(this).apply {
            text = label
            setOnClickListener { action() }
            toolbar.addView(this, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        button("Done") { finish() }
        button("Home") { browser.loadUrl(HOME) }
        button("Reload") { browser.reload() }
        button("Forget login") { forgetLogin() }
        layout.addView(toolbar)
        val address = EditText(this).apply {
            hint = "Paste Free Press article or sign-in link"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
            isSaveEnabled = false
        }
        layout.addView(address)
        layout.addView(Button(this).apply {
            text = "Open link in this app"
            setOnClickListener {
                val value = address.text.toString().trim()
                address.text.clear()
                if (allowedUrl(value)) browser.loadUrl(value)
                else status.text = "Only HTTPS links on The Free Press or Substack can open here. Other sign-in providers are not supported by this check."
            }
        })
        importButton = Button(this).apply {
            text = "Save and read in DogReader"
            isEnabled = false
            setOnClickListener { captureArticle() }
        }
        layout.addView(importButton)
        browser = WebView(this).apply {
            isSaveEnabled = false
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setSupportMultipleWindows(false)
                javaScriptCanOpenWindowsAutomatically = false
                mediaPlaybackRequiresUserGesture = true
                if (Build.VERSION.SDK_INT >= 26) safeBrowsingEnabled = true
            }
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
            webChromeClient = object : WebChromeClient() {
                override fun onConsoleMessage(message: ConsoleMessage?): Boolean = true
            }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    // Secure publisher-owned page resources may include verification
                    // frames on another host. Restrict top-level navigation only.
                    if (!request.isForMainFrame) return request.url.scheme != "https"
                    if (allowedUrl(request.url.toString())) return false
                    status.text = "This destination cannot open in the login check. Use the site's email sign-in if available."
                    return true
                }
                override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                    pageLoading = true
                    importButton.isEnabled = false
                    status.text = "Loading article…"
                }
                override fun onPageFinished(view: WebView, url: String?) {
                    CookieManager.getInstance().flush()
                    pageLoading = false
                    importButton.isEnabled = articleUrl(url ?: "") != null && !capturing
                    status.text = if (importButton.isEnabled) "Article ready. Save it to read and listen in DogReader." else "Sign in here, then open a Free Press article."
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) {
                        pageLoading = false
                        importButton.isEnabled = false
                        status.text = "Page could not load. Check your connection, then reload."
                    }
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    handler.cancel()
                    status.text = "The secure connection could not be verified."
                }
            }
        }
        layout.addView(browser, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(layout)
        browser.loadUrl(articleUrl(intent.getStringExtra("articleUrl") ?: "") ?: HOME)
    }

    private fun captureArticle() {
        val source = articleUrl(browser.url ?: "") ?: return
        if (pageLoading || capturing) return
        capturing = true
        importButton.isEnabled = false
        try {
            val script = assets.open("freepress_extract.js").bufferedReader().use { it.readText() }
            browser.evaluateJavascript(script) { raw ->
                if (isFinishing || isDestroyed) return@evaluateJavascript
                try {
                    if (pageLoading || articleUrl(browser.url ?: "") != source) throw IllegalStateException()
                    val payload = JSONTokener(raw).nextValue() as? String ?: throw IllegalStateException()
                    if (payload.length > 220000) throw IllegalStateException()
                    val captured = JSONObject(payload)
                    if (captured.has("error")) {
                        status.text = when (captured.getString("error")) {
                            "PAYWALL" -> "This page still shows a subscriber preview. Sign in and open the complete article before saving."
                            "TOO_LARGE" -> "This article is too large for a single import. No article was saved."
                            else -> "Article text is not ready. Wait for it to load, then try again."
                        }
                        resetCapture()
                        return@evaluateJavascript
                    }
                    captured.put("url", source) // Public canonical URL only; never a sign-in query or fragment.
                    val blocks = captured.getJSONArray("blocks")
                    val ending = blocks.getJSONObject(blocks.length() - 1).getString("text").takeLast(700)
                    AlertDialog.Builder(this)
                        .setTitle("Save full article?")
                        .setMessage("${captured.getString("title")}\n\nLast paragraph:\n$ending\n\nConfirm this is the article's ending. A separate full-text copy keeps existing recordings and reading positions available.")
                        .setNegativeButton("Cancel") { _, _ -> resetCapture() }
                        .setOnCancelListener { resetCapture() }
                        .setPositiveButton("Save and read") { _, _ ->
                            // Recheck navigation after the review dialog before returning article-only data.
                            if (!pageLoading && articleUrl(browser.url ?: "") == source) {
                                browser.stopLoading()
                                setResult(RESULT_OK, Intent().putExtra("article", captured.toString()))
                                finish()
                            } else resetCapture()
                        }.show()
                } catch (_: Exception) {
                    status.text = "This article could not be captured. Reload it and try again."
                    resetCapture()
                }
            }
        } catch (_: Exception) {
            status.text = "This article could not be captured. Please try again."
            resetCapture()
        }
    }

    private fun resetCapture() {
        capturing = false
        importButton.isEnabled = !pageLoading && articleUrl(browser.url ?: "") != null
    }

    private fun forgetLogin() {
        AlertDialog.Builder(this)
            .setTitle("Forget Free Press login on this device?")
            .setMessage("Removes only this embedded browser's cookies and site storage. Your library, RSS subscriptions, progress and audio are kept.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Forget login") { _, _ ->
                browser.stopLoading()
                browser.loadUrl("about:blank")
                CookieManager.getInstance().removeAllCookies {
                    WebStorage.getInstance().deleteAllData()
                    browser.clearCache(true)
                    browser.clearHistory()
                    CookieManager.getInstance().flush()
                    browser.loadUrl(HOME)
                }
            }.show()
    }

    @Deprecated("Legacy Android back callback")
    override fun onBackPressed() {
        if (browser.canGoBack()) browser.goBack() else finish()
    }

    override fun onStop() {
        if (::browser.isInitialized) CookieManager.getInstance().flush()
        super.onStop()
    }

    override fun onDestroy() {
        if (::browser.isInitialized) {
            browser.stopLoading()
            (browser.parent as? android.view.ViewGroup)?.removeView(browser)
            browser.destroy()
        }
        super.onDestroy()
    }
}
