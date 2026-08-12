// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

const script = document.currentScript;
if (!script) {
    throw new Error('No current script found.');
}

const resource = script.dataset.resource;
if (!resource) {
    throw new Error('No resource specified in data-resource attribute.');
}

// Fixup h1 text to match the resource name.
const resourceNameElement = document.getElementById('resource-name');
if (resourceNameElement) {
    resourceNameElement.textContent = resource.charAt(0).toUpperCase() + resource.slice(1);
} else {
    console.warn('No h1 element with id "resource-name" found.');
}

const spec_string = script.dataset.fields; // e.g., "name:text,level:number"
if (!spec_string) {
    throw new Error('No fields specified in data-fields attribute.');
}

/**
 * @param {string} spec
 * @returns {{name: string, type: string, header_name: string}[]}
 */
function parseSpec(spec) {
    const fields = spec.split(','); // e.g., ["name:text", "level:number"]
    return fields.map(field => {
        const split = field.split(':');

        let header_name = split[0];
        if (split.length > 2) {
            header_name = split[2];
        } else {
            header_name = header_name.split('.')[0];
        }
        header_name = header_name.charAt(0).toUpperCase() + header_name.slice(1);

        const name = split[0];
        const type = split[1];
        return { name, type, header_name };
    });
}

const fields = parseSpec(spec_string);

async function fetchRoster() {
    const response = await fetch(`/${resource}`, {
        headers: {
            'Accept': 'application/json'
        }
    });
    if (!response.ok) {
        console.error('Failed to fetch roster:', response.statusText);
        return;
    }


    const rosterTable = /** @type {HTMLTableElement | null} */ (document.getElementById('roster'));
    if (!rosterTable) {
        console.error('No roster table found in the DOM.');
        return;
    }

    rosterTable.innerHTML = '';

    // Table header.
    const tableHeader = rosterTable.createTHead();
    const headerRow = tableHeader.insertRow();
    for (const field of fields) {
        const headerCell = headerRow.insertCell();
        headerCell.textContent = field.header_name;
    }

    // Table body.
    const tableBody = rosterTable.createTBody(); // Create a tbody for the data rows
    const items = await response.json();
    for (const item of items) {
        const row = tableBody.insertRow();
        for (const field of fields) {
            const cell = row.insertCell();
            const path = field.name.split('.'); // Handle nested fields like "kin.name"
            const value = path.reduce((obj, key) => (obj && obj[key] !== undefined) ? obj[key] : null, item);

            if (field.type === 'icon') {
                const span = document.createElement('span');
                span.className = `icon`;
                span.style.cssText = `--icon:url('icons/${value}.svg')`;
                cell.appendChild(span);
            } else {
                if (value === null || value === undefined) {
                    cell.textContent = '<error>';
                } else {
                    cell.textContent = value;
                }
            }
        }
    }
}


// Fetch the roster when the page loads
window.addEventListener('load', fetchRoster);

/**
 * Fetch options for the select element.
 * @param {HTMLSelectElement} selectElement
 * @param {string} resourceName
 */
function initializeSelect(selectElement, resourceName) {
    fetch(`/${resourceName}`, {
        headers: {
            'Accept': 'application/json'
        }
    })
        .then(response => {
            if (!response.ok) {
                throw new Error(`Failed to fetch ${resourceName}: ${response.statusText}`);
            }
            return response.json();
        })
        .then(options => {
            for (const option of options) {
                const opt = document.createElement('option');
                opt.value = option.id; // Assuming each option has an 'id' field
                opt.textContent = option.name; // Assuming each option has a 'name' field
                selectElement.appendChild(opt);
            }
        })
        .catch(error => {
            console.error(`Error fetching ${resourceName}:`, error);
        });
}

function initializeForm() {
    // Find form by ID.
    const instanceForm = /** @type {HTMLFormElement | null} */ (document.getElementById('instance-form'));
    if (!instanceForm) {
        throw new Error('No instance form found in the DOM.');
    }

    for (const child of instanceForm.childNodes) {
        if (child instanceof HTMLSelectElement && child.dataset.resource) {
            initializeSelect(child, child.dataset.resource);
        }
    }

    // Add an event listener for form submission.
    instanceForm.addEventListener('submit', async (event) => {
        event.preventDefault(); // Prevent the default form submission behavior.

        const newInstance = Object.fromEntries(new FormData(instanceForm));

        try {
            // Send a POST request to the server to add the new instance.
            const response = await fetch(`/${resource}`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(newInstance)
            });

            if (!response.ok) {
                throw new Error(`Failed to add instance: ${response.statusText}`);
            }

            // Clear the form inputs after successful submission.
            instanceForm.reset();

            // Refresh the roster to include the newly added instance.
            await fetchRoster();
        } catch (error) {
            console.error('Error adding instance:', error);
        }
    });
}

initializeForm();
