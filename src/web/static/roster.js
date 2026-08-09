// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

const script = document.currentScript;
const resource = script.dataset.resource;
const spec = script.dataset.fields; // e.g., "name:text,level:number"

function parseSpec(spec) {
    const fields = spec.split(','); // e.g., ["name:text", "level:number"]
    return fields.map(field => {
        const [name, type] = field.split(':');
        return { name, type };
    });
}

const fields = parseSpec(spec);

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

    const rosterTable = document.getElementById('roster');
    rosterTable.innerHTML = '';

    // Table header.
    const tableHeader = rosterTable.createTHead()
    const headerRow = tableHeader.insertRow();
    for (const field of fields) {
        const headerCell = headerRow.insertCell();
        headerCell.textContent = field.name.charAt(0).toUpperCase() + field.name.slice(1);
    }

    // Table body.
    const tableBody = rosterTable.createTBody(); // Create a tbody for the data rows
    const items = await response.json();
    items.forEach(item => {
        const row = tableBody.insertRow();

        for (const field of fields) {
            const cell = row.insertCell();
            cell.textContent = item[field.name];
        }
    });
}


// Fetch the roster when the page loads
window.addEventListener('load', fetchRoster);

// Find character-form by ID.
const characterForm = document.getElementById('character-form');

// Add an event listener for form submission.
characterForm.addEventListener('submit', async (event) => {
    event.preventDefault(); // Prevent the default form submission behavior.

    // Get the character name and level from the form inputs.
    const characterName = document.getElementById('character-name').value;
    const characterLevel = parseInt(document.getElementById('character-level').value, 10);

    // Create a new character object.
    const newCharacter = {
        name: characterName,
        level: characterLevel
    };

    try {
        // Send a POST request to the server to add the new character.
        const response = await fetch(`/${resource}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(newCharacter)
        });

        if (!response.ok) {
            throw new Error(`Failed to add character: ${response.statusText}`);
        }

        // Clear the form inputs after successful submission.
        characterForm.reset();

        // Refresh the roster to include the newly added character.
        await fetchRoster();
    } catch (error) {
        console.error('Error adding character:', error);
    }
});
