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