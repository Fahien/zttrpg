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
 * @returns {{name: string, type: string}[]}
 */
function parseSpec(spec) {
    const fields = spec.split(','); // e.g., ["name:text", "level:number"]
    return fields.map(field => {
        const [name, type] = field.split(':');
        return { name, type };
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
        headerCell.textContent = field.name.charAt(0).toUpperCase() + field.name.slice(1);
    }

    // Table body.
    const tableBody = rosterTable.createTBody(); // Create a tbody for the data rows
    const items = await response.json();
    for (const item of items) {
        const row = tableBody.insertRow();
        for (const field of fields) {
            const cell = row.insertCell();
            cell.textContent = item[field.name];
        }
    }
}


// Fetch the roster when the page loads
window.addEventListener('load', fetchRoster);

function initializeForm() {
    // Find form by ID.
    const instanceForm = /** @type {HTMLFormElement | null} */ (document.getElementById('instance-form'));
    if (!instanceForm) {
        throw new Error('No instance form found in the DOM.');
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
