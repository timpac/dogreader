(function () {
  'use strict';
  // Deliberately read rendered article elements only. Never serialize the DOM,
  // scripts, application state, forms, cookies, localStorage or request headers.
  const visible = el => {
    if (!el || !el.getClientRects().length || el.closest('[hidden],[aria-hidden="true"],[inert]')) return false;
    for (let node = el; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0' || style.contentVisibility === 'hidden') return false;
    }
    return true;
  };
  const text = el => {
    const read = node => {
      if (node.nodeType === Node.TEXT_NODE) return node.nodeValue;
      if (node.nodeType !== Node.ELEMENT_NODE || !visible(node) || node.closest('script,style,nav,footer,aside,form,input,textarea,select')) return '';
      const value = Array.from(node.childNodes).map(read).join('');
      // Preserve inline word boundaries while separating nested block elements.
      return /^(?:P|DIV|LI|BLOCKQUOTE|BR|H[1-6])$/.test(node.tagName) ? ' ' + value + ' ' : value;
    };
    return visible(el) ? read(el).replace(/\s+/g, ' ').trim() : '';
  };
  const paywallWords = /(?:this (?:post|article) is for (?:paid |paying )?subscribers|subscribe to (?:read|continue|unlock)|continue reading (?:with|by)|already (?:a (?:paid )?subscriber|have an account)\??\s*(?:sign|log) in)/i;
  for (const el of document.querySelectorAll('.paywall, .paywall-overlay, .subscription-widget, [data-testid="paywall"], .paywall-content')) {
    if (visible(el) && paywallWords.test(text(el))) return JSON.stringify({error: 'PAYWALL'});
  }
  const selectors = ['.available-content .body.markup', '.available-content .body', '.body.markup', '[data-testid="post-content"]', 'article .body', 'article'];
  for (const selector of selectors) {
    const roots = Array.from(document.querySelectorAll(selector)).filter(visible);
    for (const root of roots) {
      const blocks = [];
      let size = 0;
      for (const el of root.querySelectorAll('h2,h3,h4,h5,p,blockquote,li,hr')) {
        if (!visible(el) || el.closest('nav,footer,aside,form,[role="dialog"],.comments-section,.post-footer,.subscription-widget')) continue;
        // Quote/list containers own their child paragraphs; never emit them twice.
        if (el.parentElement.closest('blockquote,li') && root.contains(el.parentElement.closest('blockquote,li'))) continue;
        const value = el.tagName === 'HR' ? '⁂' : text(el);
        if (!value) continue;
        if (paywallWords.test(value)) return JSON.stringify({error: 'PAYWALL'});
        size += value.length;
        if (size > 180000 || blocks.length >= 1500) return JSON.stringify({error: 'TOO_LARGE'});
        const tag = el.tagName;
        blocks.push({text: value, kind: /^H[2-5]$/.test(tag) ? 'heading' : tag === 'LI' ? 'list' : tag === 'BLOCKQUOTE' ? 'quote' : tag === 'HR' ? 'break' : 'paragraph'});
      }
      const words = blocks.map(b => b.text).join(' ').trim().split(/\s+/).length;
      if (size < 500 || words < 100) continue;
      const title = text(document.querySelector('h1'));
      if (!title || title.length > 500) return JSON.stringify({error: 'NO_ARTICLE'});
      return JSON.stringify({title: title, blocks: blocks});
    }
  }
  return JSON.stringify({error: 'NO_ARTICLE'});
})()
