// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

async function fetchRoster() {
    const response = await fetch('/characters');
    if (!response.ok) {
        console.error('Failed to fetch roster:', response.statusText);
        return;
    }
    const characters = await response.json();
    const rosterTable = document.getElementById('roster');
    rosterTable.innerHTML = '';
    characters.forEach(character => {
        const row = rosterTable.insertRow();
        row.insertCell().textContent = character.id;
        row.insertCell().textContent = character.name;
        row.insertCell().textContent = character.level;
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
        const response = await fetch('/characters', {
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
