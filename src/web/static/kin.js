// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

async function getIdFromUrl() {
    // Get the ID from the URL which is in this format: /kins/<id>
    const url_after_slash = window.location.pathname.split('/').pop();
    const url_part = url_after_slash.split('?')[0];
    const id = parseInt(url_part, 10);
    if (isNaN(id)) {
        console.error('Invalid kin ID in URL:', url_part);
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

    const kinDetails = document.getElementById('kin-details');
    kinDetails.hidden = true;
}

async function fetchKin() {
    const id = await getIdFromUrl();
    if (id === undefined) {
        reportError('Invalid kin ID in URL.');
        return;
    }

    const response = await fetch(`/kins/${id}`, {
        headers: {
            'Accept': 'application/json'
        }
    });
    if (!response.ok) {
        reportError(`Failed to fetch kin data: ${response.status} ${response.statusText}`);
        return;
    }

    const kin = await response.json();
    document.getElementById('kin-name').textContent = kin.name;
}

// Fetch the roster when the page loads
window.addEventListener('load', fetchKin);
