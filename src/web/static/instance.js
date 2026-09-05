// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

function initInstancePage() {
    const script = document.currentScript;
    if (!script) {
        throw new Error('No current script found.');
    }

    const resource = script.dataset.resource;
    if (!resource) {
        throw new Error('No resource specified in data-resource attribute.');
    }

    async function getIdFromUrl() {
        // Get the ID from the URL which is in this format: /<resource>/<id>
        const url_after_slash = window.location.pathname.split('/').pop();
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
     * @param {*} obj The object to resolve the path from.
     * @param {string[]} path The path to resolve, as an array of keys.
     * @returns {*} The resolved value, or null if not found.
     */
    function resolvePath(obj, path) {
        return path.reduce((acc, key) => (acc && acc[key] !== undefined) ? acc[key] : null, obj);
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

            const path = fieldName.split('.'); // Handle nested fields like "kin.name"
            const value = resolvePath(root, path);
            if (value === null || value === undefined) {
                console.warn(`Field "${fieldName}" not found in root data:`, root);
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
    function expandList(root, scope) {
        const dataLists = /** @type {NodeListOf<HTMLElement>} */ (scope.querySelectorAll('[data-list]'));
        for (const list of dataLists) {
            if (!list.dataset.list) {
                console.warn('No data-list attribute found for element:', list);
                continue;
            }

            const listName = list.dataset.list;

            const path = listName.split('.'); // Handle nested fields like "kin.name"
            const value = resolvePath(root, path);
            if (value === null || value === undefined) {
                console.warn(`Field "${listName}" not found in root data:`, root);
                continue;
            }

            if (!Array.isArray(value)) {
                console.warn(`Field "${listName}" is not an array in root data:`, root);
                continue;
            }

            // Find the template element within the list.
            const template = /** @type {HTMLTemplateElement} */ (list.querySelector('template'));
            if (!template) {
                console.warn('No template found for list element:', list);
                continue;
            }

            for (const item of value) {
                // Clone the template content and bind fields for each item.
                const clone = document.importNode(template.content, true);
                bindFields(item, clone);
                expandList(item, clone);
                list.appendChild(clone);
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

        const item = await response.json();
        bindFields(item, document);
        expandList(item, document);

        // Dispatch an event announcing that the instance has been loaded, so other scripts can react to it.
        const event = new CustomEvent('instanceLoaded', { detail: item });
        document.dispatchEvent(event);
    }

    // Fetch the instance when the page loads
    window.addEventListener('load', fetchInstance);
}

initInstancePage();