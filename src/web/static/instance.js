// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

/**
 * @param {*} obj
 * @param {string[]} path
 * @returns {*} The value, including null, or undefined for a missing field.
 */
function resolvePath(obj, path) {
    let value = obj;
    for (const key of path) {
        // An optional object may legitimately be null.
        if (value === null || value === undefined) return value;
        value = value[key];
    }
    return value;
}

/** @param {*} root @param {string} fieldName */
function resolveFieldName(root, fieldName) {
    const value = resolvePath(root, fieldName.split('.'));
    if (value === undefined) {
        console.warn(`Field "${fieldName}" not found in data:`, root);
    }
    return value;
}

/** @param {string} template @param {Record<string, unknown>} data */
function interpolate(template, data) {
    return template.replace(/\{([^{}]+)\}/g, (_match, field) => {
        return String(resolveFieldName(data, field.trim()) ?? '');
    });
}

/**
 * Retains original templates and row scopes so update() can render again.
 * Existing rows survive value edits; changed array entries rebuild that list.
 *
 * @param {Document | DocumentFragment | Element} root
 * @param {Record<string, unknown>} data
 * @returns {{data: Record<string, unknown>, update: () => void}}
 */
function createView(root, data) {
    // Each binding is a function that remembers its node, template and scope.
    /** @typedef {() => void} Binding */
    /** @typedef {{item: unknown, nodes: Node[], bindings: Binding[]}} Row */

    /** @param {Node} scope @param {Record<string, unknown>} data @returns {Binding[]} */
    function discoverBindings(scope, data) {
        /** @type {Binding[]} */
        const bindings = [];

        /** @param {Text | Attr} node */
        function bindTemplate(node) {
            const template = node.nodeValue ?? '';
            if (!/\{([^{}]+)\}/.test(template)) return;
            bindings.push(() => {
                const value = interpolate(template, data);
                if (node.nodeValue !== value) node.nodeValue = value;
            });
        }

        /** @param {HTMLElement} element @param {'show' | 'hide'} directive */
        function bindVisibility(element, directive) {
            const path = element.dataset[directive];
            if (!path) return;
            const expected = element.dataset[`${directive}Value`];
            bindings.push(() => {
                const value = resolveFieldName(data, path);
                const matches = expected === undefined
                    ? (Array.isArray(value) ? value.length > 0 : Boolean(value))
                    : expected === 'null' ? value === null : String(value) === expected;
                element.hidden = directive === 'show' ? !matches : matches;
            });
        }

        /** @param {HTMLElement} list */
        function bindIteration(list) {
            const path = list.dataset.iter?.trim();
            const alias = list.dataset.as?.trim();
            const template = list.querySelector(':scope > template');
            if (!path || !alias || !(template instanceof HTMLTemplateElement)) {
                console.warn('Iteration needs data-iter, data-as and a direct child template:', list);
                return;
            }
            /** @type {Row[]} */
            let rows = [];
            bindings.push(() => {
                const value = resolveFieldName(data, path);
                if (!Array.isArray(value)) {
                    console.warn(`Field "${path}" must be an array for data-iter:`, list);
                }
                const items = Array.isArray(value) ? value : [];
                const changed = items.length !== rows.length || items.some((item, i) => item !== rows[i].item);
                if (changed) {
                    for (const row of rows) {
                        for (const node of row.nodes) node.parentNode?.removeChild(node);
                    }
                    rows = items.map(item => {
                        const clone = document.importNode(template.content, true);
                        // Inherit enclosing names; keep the item name local to this row.
                        // Replacing data.character is then visible to existing rows too.
                        const rowData = Object.assign(Object.create(data), { [alias]: item });
                        const row = {
                            item,
                            nodes: Array.from(clone.childNodes),
                            bindings: discoverBindings(clone, rowData),
                        };
                        list.appendChild(clone);
                        return row;
                    });
                }
                for (const row of rows) {
                    for (const render of row.bindings) render();
                }
            });
        }

        /** @param {Node} node */
        function visit(node) {
            if (node instanceof Text) {
                bindTemplate(node);
                return;
            }
            if (node instanceof Element && node.matches('script, style, template')) return;
            if (node instanceof HTMLElement) {
                for (const attribute of node.attributes) {
                    const supported = ['title', 'href', 'value'].includes(attribute.name)
                        || attribute.name.startsWith('data-') || attribute.name.startsWith('aria-');
                    if (supported) bindTemplate(attribute);
                }
                // Attribute bindings resolve the name before this updates the mask.
                if (node.hasAttribute('data-icon')) {
                    bindings.push(() => {
                        const name = node.dataset.icon;
                        node.style.setProperty('--icon', name
                            ? `url("/static/icons/${encodeURIComponent(name)}.svg")`
                            : 'none');
                    });
                }
                bindVisibility(node, 'show');
                bindVisibility(node, 'hide');
                if (node.hasAttribute('data-iter')) bindIteration(node);
            }
            for (const child of node.childNodes) visit(child);
        }

        visit(scope);
        return bindings;
    }

    const bindings = discoverBindings(root, data);
    function update() {
        for (const render of bindings) render();
    }
    update();
    return { data, update };
}

function initInstancePage() {
    const script = document.currentScript;
    if (!(script instanceof HTMLScriptElement)) throw new Error('No current script found.');
    const resource = script.dataset.resource;
    const bindingName = script.dataset.as;
    if (!resource) throw new Error('No resource specified in data-resource attribute.');
    if (!bindingName) throw new Error('No binding name specified in data-as attribute.');

    /** @param {string} message */
    function reportError(message) {
        console.error(message);
        const statusMessage = document.getElementById('status-message');
        if (statusMessage) {
            statusMessage.hidden = false;
            statusMessage.classList.add('error');
            statusMessage.textContent = message;
        }
        const itemDetails = document.getElementById('instance-details');
        if (itemDetails) itemDetails.hidden = true;
    }

    async function fetchInstance() {
        const urlId = window.location.pathname.split('/')[2] ?? '';
        if (!/^\d+$/.test(urlId) || !Number.isSafeInteger(Number(urlId)) || Number(urlId) < 1) {
            reportError('Invalid instance ID in URL.');
            return;
        }
        try {
            const response = await fetch(`/${resource}/${urlId}`, {
                headers: { 'Accept': 'application/json' },
            });
            if (!response.ok) {
                reportError(`Failed to fetch instance data: ${response.status} ${response.statusText}`);
                return;
            }
            const instance = await response.json();
            // Let page scripts prepare derived lists and drafts before binding.
            document.dispatchEvent(new CustomEvent('instanceFetched', { detail: instance }));
            const view = createView(document, { [bindingName]: instance });
            document.dispatchEvent(new CustomEvent('bindingsReady', { detail: view }));
            document.dispatchEvent(new CustomEvent('instanceLoaded', { detail: instance }));
        } catch (error) {
            reportError(`Failed to load instance: ${error instanceof Error ? error.message : String(error)}`);
        }
    }

    window.addEventListener('load', fetchInstance);
}

initInstancePage();
