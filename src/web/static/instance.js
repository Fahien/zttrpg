// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check


/**
 * @param {*} obj The object to resolve the path from.
 * @param {string[]} path The path to resolve, as an array of keys.
 * @returns {*} The resolved value, or null if not found.
 */
function resolvePath(obj, path) {
    return path.reduce((acc, key) => (acc && acc[key] !== undefined) ? acc[key] : null, obj);
}

/**
 * @param {*} root
 * @param {string} fieldName
 * @returns {*} The resolved value, or null if not found.
 */
function resolveFieldName(root, fieldName) {
    const path = fieldName.split('.'); // Handle nested fields like "kin.name"
    const value = resolvePath(root, path);
    if (value === null || value === undefined) {
        console.warn(`Field "${fieldName}" not found in root data:`, root);
    }
    return value;
}

/**
 * This function takes a template, such as "Hello {name}", and inserts values into it.
 * `Record<string, unknown>` means an object with string keys whose value types are not assumed in advance.
 * 
 * @param {string} template The original string containing placeholders like "{name}".
 * @param {Record<string, unknown>} data The object from which to read their values.
 * @returns {string} The template with those placeholders replaced.
 */
function interpolate(template, data) {
    return template.replace(/\{([^{}]+)\}/g, (_match, field) => {
        const path = field.trim();
        const value = resolveFieldName(data, path);
        return String(value ?? '');
    });
}



/**
 * Creates and renders bindings within a container.
 *
 * @param {Document | DocumentFragment | Element} root
 * @param {Record<string, unknown>} data
 * @returns {{data: Record<string, unknown>, update: () => void}}
 */
function createView(root, data) {
    /**
     * @typedef {Object} Binding
     * @property {Text | Attr} node
     * @property {string} template
     * @property {Record<string, unknown>} data
     */

    /** @type {Binding[]} */
    const bindings = [];

    /**
     * Discovers {field.path} placeholders in descendant text and attribute nodes.
     * Skips scripts and styles.
     *
     * @param {Document | DocumentFragment | Element} scope Search container.
     * @param {Record<string, unknown>} data The data used by this group of text nodes.
     * @returns {void}
     */
    function discoverBindings(scope, data) {
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (node.parentElement?.closest('script, style')) continue;
            const text_node = /** @type {Text} */ (node);
            // If node data contains placeholders like {field.path}, collect node and template.
            if (!/\{([^{}]+)\}/.test(text_node.data)) {
                continue;
            }
            bindings.push({
                node: text_node,
                template: text_node.data,
                data,
            });
        }

        for (const element of scope.querySelectorAll('*')) {
            if (element.closest('script, style')) {
                continue;
            }
            for (const attribute of element.attributes) {
                const supported =
                    ['title', 'href', 'value'].includes(attribute.name) ||
                    attribute.name.startsWith('data-') ||
                    attribute.name.startsWith('aria-');

                if (!supported || !/\{([^{}]+)\}/.test(attribute.value)) {
                    continue;
                }

                bindings.push({
                    node: attribute,
                    template: attribute.value,
                    data,
                });
            }
        }
    }

    /**
     * Re-renders existing text and attribute nodes from their saved templates and data objects.
     * Call after mutating those objects. This does not add, remove, or replace rows.
     * @returns {void}
     */
    function updateBindings() {
        for (const binding of bindings) {
            const value = interpolate(binding.template, binding.data);
            if (binding.node.nodeValue !== value) {
                binding.node.nodeValue = value;
            }
        }
    }

    /**
     * Creates one copy of a direct child template for each item in data-iter.
     * data-as names the item within each row's data object.
     *
     * @param {Record<string, unknown>} data The enclosing page or row data.
     * @param {Document | DocumentFragment | Element} scope Search container.
     */
    function expandIterations(data, scope) {
        const lists = /** @type {NodeListOf<HTMLElement>} */ (scope.querySelectorAll('[data-iter]'));
        for (const list of lists) {
            const path = list.dataset.iter?.trim();
            const alias = list.dataset.as?.trim();
            if (!path || !alias) {
                console.warn('Iteration needs both data-iter and data-as:', list);
                continue;
            }

            const items = resolveFieldName(data, path);
            if (!Array.isArray(items)) {
                console.warn(`Field "${path}" must be an array for data-iter:`, list);
                continue;
            }

            const template = list.querySelector(':scope > template');
            if (!(template instanceof HTMLTemplateElement)) {
                console.warn('Iteration needs a direct child template:', list);
                continue;
            }

            for (const item of items) {
                const clone = document.importNode(template.content, true);
                // Copy the enclosing names, then give this row its own item name.
                // The character and item remain references to the original objects.
                const rowData = { ...data, [alias]: item };
                discoverBindings(clone, rowData);
                // Discover before expanding: nested rows must keep their own data.
                expandIterations(rowData, clone);
                list.appendChild(clone);
            }
        }
    }

    discoverBindings(root, data);
    expandIterations(data, root);
    updateBindings();

    return {
        data,
        update: updateBindings,
    };
}

function initInstancePage() {
    const script = document.currentScript;
    if (!script) {
        throw new Error('No current script found.');
    }

    const resource = script.dataset.resource;
    if (!resource) {
        throw new Error('No resource specified in data-resource attribute.');
    }

    if (!script.dataset.as) {
        throw new Error('No binding name specified in data-as attribute.');
    }
    /** @type {string} */
    const bindingName = script.dataset.as;

    async function getIdFromUrl() {
        // Get the ID from the URL which is in this format: /<resource>/<id>
        const url_after_slash = window.location.pathname.split('/').at(2);
        if (!url_after_slash) {
            console.error('No ID found in URL.');
            return;
        }

        const url_part = url_after_slash.split('?')[0];

        const id = parseInt(url_part, 10);
        if (isNaN(id)) {
            console.error('Invalid instance ID in URL:', url_part);
            return;
        }
        return id;
    }

    /**
     * @param {string} message
     */
    async function reportError(message) {
        console.error(message);
        const statusMessage = document.getElementById('status-message');
        if (!statusMessage) {
            console.error('No status message element found in the DOM.');
            return;
        }
        statusMessage.hidden = false;
        statusMessage.classList.add('error');
        statusMessage.textContent = message;

        const itemDetails = document.getElementById('instance-details');
        if (!itemDetails) {
            console.error('No instance details element found in the DOM.');
            return;
        }
        itemDetails.hidden = true;
    }

    /**
     * @param {*} root The root data object.
     * @param {*} scope The scope element to search for data-field elements within.
     */
    function bindFields(root, scope) {
        const dataFields = /** @type {NodeListOf<HTMLElement>} */ (scope.querySelectorAll('[data-field]'));
        for (const field of dataFields) {
            if (!field.dataset.field) {
                console.warn('No data-field attribute found for element:', field);
                continue;
            }

            const [fieldName, fieldType] = field.dataset.field.split(':');
            if (!fieldName) {
                console.warn(`No value found for field "${fieldName}" in element:`, field);
                continue;
            }

            const value = resolveFieldName(root, fieldName);
            if (value === null || value === undefined) {
                continue;
            }

            if (fieldType?.startsWith('data-')) {
                field.setAttribute(fieldType, value);
            } else if (fieldType === 'icon') {
                field.className = `icon`;
                field.style.cssText = `--icon:url('/static/icons/${value}.svg'); color: var(--text-main);`;
            } else {
                field.textContent = value;
            }
        }
    }


    /**
     * @param {*} root The root data object.
     * @param {*} scope The scope element to search for data-list elements within.
     */
    async function checkDataHide(root, scope) {
        const sections = /** @type {NodeListOf<HTMLElement>} */ (scope.querySelectorAll('[data-hide]'));
        for (const section of sections) {
            const field = section.dataset.hide;

            if (field === undefined || field === '') {
                console.warn('No data-hide attribute found for element:', section);
                continue;
            }
            const value = resolveFieldName(root, field);
            if (value === undefined || value === null) {
                section.hidden = true;
            }

            const hideValue = section.dataset.hideValue;
            if (hideValue !== undefined) {
                section.hidden = value == hideValue;
            }
            else if (!value || (Array.isArray(value) && value.length === 0)) {
                section.hidden = true;
            } else {
                section.hidden = false;
            }
        }
    }

    /**
   * @param {*} root The root data object.
   * @param {*} scope The scope element to search for data-list elements within.
   */
    async function checkDataShow(root, scope) {
        const sections = /** @type {NodeListOf<HTMLElement>} */ (scope.querySelectorAll('[data-show]'));
        for (const section of sections) {
            const field = section.dataset.show;
            if (field === undefined || field === '') {
                console.warn('No data-show attribute found for element:', section);
                continue;
            }
            const value = resolveFieldName(root, field);

            let showValue = /** @type {string | null} */ (section.dataset.showValue);
            if (showValue !== undefined && showValue !== null) {
                if (showValue == "null") {
                    showValue = null;
                }
                section.hidden = value !== showValue;
            }
            else if (value === undefined || value === null) {
                section.hidden = true;
            }
            else if (typeof value === 'number') {
                // If number, show if != 0
                section.hidden = value === 0;
            }
            else if ((Array.isArray(value) && value.length === 0)) {
                section.hidden = true;
            } else {
                section.hidden = value ? false : true;
            }
        }
    }

    async function fetchInstance() {
        const id = await getIdFromUrl();
        if (id === undefined) {
            reportError('Invalid instance ID in URL.');
            return;
        }

        const response = await fetch(`/${resource}/${id}`, {
            headers: {
                'Accept': 'application/json'
            }
        });
        if (!response.ok) {
            reportError(`Failed to fetch instance data: ${response.status} ${response.statusText}`);
            return;
        }

        const instance = await response.json();
        // Dispatch an event announcing that the instance has been loaded, so other scripts can react to it.
        const event = new CustomEvent('instanceFetched', { detail: instance });
        document.dispatchEvent(event);

        bindFields(instance, document);
        checkDataHide(instance, document);
        checkDataShow(instance, document);

        const data = { [bindingName]: instance };
        const view = createView(document, data);

        document.dispatchEvent(new CustomEvent('bindingsReady', {
            detail: view,
        }));
        document.dispatchEvent(new CustomEvent('instanceLoaded'));
    }

    // Fetch the instance when the page loads
    window.addEventListener('load', fetchInstance);
}

initInstancePage();
