// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

async function fetchRoster() {
    const response = await fetch('/kins', {
        headers: {
            'Accept': 'application/json'
        }
    });
    if (!response.ok) {
        console.error('Failed to fetch roster:', response.statusText);
        return;
    }
    const kins = await response.json();
    const rosterTable = document.getElementById('roster');
    rosterTable.innerHTML = '';
    kins.forEach(kin => {
        const row = rosterTable.insertRow();
        row.insertCell().textContent = kin.id;
        row.insertCell().textContent = kin.name;
    });
}

// Fetch the roster when the page loads
window.addEventListener('load', fetchRoster);
