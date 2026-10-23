// Runs in WebKit's isolated client world. Untrusted HTML is parsed in an inert
// template, then rebuilt from allowed elements/attributes; it is never inserted raw.
const root = document.getElementById('markdown');
const allowed = new Set('a p br hr h1 h2 h3 h4 h5 h6 strong b em i del s blockquote ul ol li pre code table thead tbody tfoot tr th td details summary sub sup ins kbd div span img input relative-time time'.split(' '));
const dropped = new Set('script style iframe object embed form svg math template link meta base noscript'.split(' '));
function safeURL(value, base, image = false) {
    try {
        const url = new URL(value, base);
        return (image ? ['https:', 'http:'] : ['https:', 'http:', 'mailto:']).includes(url.protocol) ? url.href : null;
    } catch { return null; }
}
function clean(node, base) {
    if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE) return document.createDocumentFragment();
    const tag = node.localName.toLowerCase();
    if (dropped.has(tag)) return document.createDocumentFragment();
    const element = allowed.has(tag) ? document.createElement(tag === 'relative-time' ? 'time' : tag) : document.createDocumentFragment();
    if (element.nodeType === Node.ELEMENT_NODE) {
        if (node.hasAttribute('title')) element.title = node.getAttribute('title');
        if (tag === 'a' || tag === 'img') {
            const attr = tag === 'a' ? 'href' : 'src';
            const url = node.hasAttribute(attr) && safeURL(node.getAttribute(attr), base, tag === 'img');
            if (url) element.setAttribute(attr, url);
            if (tag === 'img') element.alt = node.getAttribute('alt') || '';
        }
        if (tag === 'details' && node.hasAttribute('open')) element.open = true;
        if (tag === 'ol' && /^\d+$/.test(node.getAttribute('start') || '')) element.start = Number(node.getAttribute('start'));
        if (tag === 'input') {
            if (node.getAttribute('type') !== 'checkbox') return document.createDocumentFragment();
            element.type = 'checkbox'; element.disabled = true; element.checked = node.hasAttribute('checked');
        }
        if (['td', 'th'].includes(tag) && ['left', 'center', 'right'].includes(node.getAttribute('align'))) element.style.textAlign = node.getAttribute('align');
        if (tag === 'relative-time' || tag === 'time') {
            const date = new Date(node.getAttribute('datetime'));
            if (Number.isFinite(date.getTime())) {
                element.dateTime = date.toISOString(); element.title = date.toLocaleString();
                element.textContent = node.textContent.trim() || date.toLocaleString();
                return element;
            }
        }
    }
    for (const child of node.childNodes) element.append(clean(child, base));
    return element;
}
function renderMarkdown(html, base, dark) {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    const template = document.createElement('template');
    template.innerHTML = html;
    const fragment = document.createDocumentFragment();
    for (const child of template.content.childNodes) fragment.append(clean(child, base));
    root.replaceChildren(fragment);
    for (const table of root.querySelectorAll('table')) {
        const scroll = document.createElement('div'); scroll.className = 'table-scroll';
        table.replaceWith(scroll); scroll.append(table);
        scroll.tabIndex = 0; scroll.setAttribute('aria-label', '表（横スクロール）');
    }
    for (const pre of root.querySelectorAll('pre')) {
        const wrapper = document.createElement('div'); wrapper.className = 'code-block';
        const button = document.createElement('button'); button.textContent = 'コピー';
        button.setAttribute('aria-label', 'コードをコピー');
        button.addEventListener('click', event => {
            if (event.isTrusted) window.webkit.messageHandlers.markdownCopy.postMessage(pre.textContent);
        });
        pre.replaceWith(wrapper); wrapper.append(button, pre);
    }
    reportHeight();
}
function reportHeight() { window.webkit.messageHandlers.markdownHeight.postMessage(Math.max(1, root.getBoundingClientRect().height)); }
new ResizeObserver(reportHeight).observe(root);
root.addEventListener('toggle', reportHeight, true);
root.addEventListener('load', reportHeight, true);
