// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

async function getIdFromUrl() {
    // Get the ID from the URL which is in this format: /character/<id>
    const url_after_slash = window.location.pathname.split('/').pop();
    const url_part = url_after_slash.split('?')[0];
    const id = parseInt(url_part, 10);
    if (isNaN(id)) {
        console.error('Invalid character ID in URL:', url_part);
        return;
    }
    return id;
}

async function reportError(message) {
    console.error(message);
    const statusMessage = document.getElementById('status-message');
    statusMessage.hidden = false;
    statusMessage.classList.add('error');
    statusMessage.textContent = message;

    const characterDetails = document.getElementById('character-details');
    characterDetails.hidden = true;
}

async function fetchCharacter() {
    const id = await getIdFromUrl();
    if (id === undefined) {
        reportError('Invalid character ID in URL.');
        return;
    }

    const response = await fetch(`/characters/${id}`, {
        headers: {
            'Accept': 'application/json'
        }
    });
    if (!response.ok) {
        reportError(`Failed to fetch character data: ${response.status} ${response.statusText}`);
        return;
    }

    const character = await response.json();
    document.getElementById('character-name').textContent = character.name;
    document.getElementById('character-level').textContent = character.level;
}

// Fetch the roster when the page loads
window.addEventListener('load', fetchCharacter);
