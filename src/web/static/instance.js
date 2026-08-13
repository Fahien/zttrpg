// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

function initItemPage() {
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

    async function fetchItem() {
        const id = await getIdFromUrl();
        if (id === undefined) {
            reportError('Invalid item ID in URL.');
            return;
        }

        const response = await fetch(`/${resource}/${id}`, {
            headers: {
                'Accept': 'application/json'
            }
        });
        if (!response.ok) {
            reportError(`Failed to fetch item data: ${response.status} ${response.statusText}`);
            return;
        }

        const item = await response.json();

        const dataFields =  /** @type {NodeListOf<HTMLElement>} */ (document.querySelectorAll('[data-field]'));
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
            const value = path.reduce((obj, key) => (obj && obj[key] !== undefined) ? obj[key] : null, item);
            if (value === null || value === undefined) {
                console.warn(`Field "${fieldName}" not found in item data:`, item);
                continue;
            }

            if (fieldType === 'icon') {
                field.className = `icon`;
                field.style.cssText = `--icon:url('/static/icons/${value}.svg'); color: var(--text-main);`;
            } else {
                field.textContent = value;
            }
        }
    }

    // Fetch the item when the page loads
    window.addEventListener('load', fetchItem);
}

initItemPage();