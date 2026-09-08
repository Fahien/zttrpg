// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

const script = document.currentScript;
if (!script) {
    throw new Error('No current script found.');
}

const page = script.dataset.page;
if (page !== 'collection' && page !== 'item') {
    throw new Error('Expected a profession page type.');
}

/**
 * @param {string} message
 */
function reportError(message) {
    console.error(message);

    const statusMessage = document.getElementById('status-message');
    if (statusMessage) {
        statusMessage.hidden = false;
        statusMessage.classList.add('error');
        statusMessage.textContent = message;
    }

    const details = document.getElementById('instance-details');
    if (details) {
        details.hidden = true;
    }
}

/**
 * @param {string} path
 */
async function fetchJson(path) {
    const response = await fetch(path, { headers: { 'Accept': 'application/json' } });
    if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}`);
    }
    return response.json();
}

/**
 * @param {string} iconName
 */
function iconFrame(iconName) {
    const frame = document.createElement('span');
    frame.className = 'icon-frame';
    frame.dataset.iconSize = '1';
    // Heading text uses a transparent colour for its clipped gilt gradient;
    // the icon needs an ordinary foreground colour instead.
    frame.style.color = 'var(--text-main)';

    const icon = document.createElement('span');
    icon.className = 'icon';
    icon.style.cssText = `--icon:url('/static/icons/${iconName}.svg')`;
    frame.appendChild(icon);
    return frame;
}

/**
 * @param {string} label
 * @param {number} id
 * @param {string} resource
 */
function resourceLink(label, id, resource) {
    const link = document.createElement('a');
    link.href = `/${resource}/${id}`;
    link.textContent = label;
    return link;
}

/**
 * @param {*} profession
 */
function renderCollectionRow(profession) {
    const row = document.createElement('tr');

    const icon = row.insertCell();
    icon.appendChild(iconFrame(profession.icon.name));

    const name = row.insertCell();
    name.appendChild(resourceLink(profession.name, profession.id, 'professions'));

    const description = row.insertCell();
    description.textContent = profession.description;

    const count = row.insertCell();
    const specializationCount = profession.specializations.length;
    count.textContent = specializationCount === 1 ? '1 specialization' : `${specializationCount} specializations`;

    return row;
}

/**
 * @param {*} professions
 */
function renderCollection(professions) {
    const roster = /** @type {HTMLTableElement | null} */ (document.getElementById('roster'));
    if (!roster) {
        throw new Error('No profession roster found.');
    }

    const colgroup = document.createElement('colgroup');
    for (const width of ['4em', '12em', '', '10em']) {
        const col = document.createElement('col');
        col.style.width = width;
        colgroup.appendChild(col);
    }
    roster.appendChild(colgroup);

    const header = roster.createTHead().insertRow();
    for (const name of ['Icon', 'Profession', 'Description', 'Specializations']) {
        const cell = document.createElement('th');
        cell.textContent = name;
        header.appendChild(cell);
    }

    const body = roster.createTBody();
    for (const profession of professions) {
        body.appendChild(renderCollectionRow(profession));
    }
}

/**
 * @param {*} skill
 */
function skillListItem(skill) {
    const entry = document.createElement('li');
    entry.className = 'profession-reference';
    entry.append(iconFrame(skill.icon.name), resourceLink(skill.name, skill.id, 'skills'));
    return entry;
}

/**
 * Groups repeat copies of a package item while preserving the order in which
 * the player receives each different item.
 * @param {*} items
 */
function itemQuantities(items) {
    /** @type {Map<number, { item: any, quantity: number }>} */
    const quantities = new Map();
    for (const item of items) {
        const present = quantities.get(item.id);
        if (present) {
            present.quantity += 1;
        } else {
            quantities.set(item.id, { item, quantity: 1 });
        }
    }
    return quantities.values();
}

/**
 * @param {*} items
 */
function gearPackage(items) {
    const list = document.createElement('ul');
    list.className = 'plain-list profession-gear';

    for (const { item, quantity } of itemQuantities(items)) {
        const entry = document.createElement('li');
        entry.className = 'profession-reference';
        entry.append(iconFrame(item.icon.name));
        if (quantity > 1) {
            const count = document.createElement('span');
            count.className = 'profession-item-count';
            count.textContent = `${quantity} ×`;
            entry.appendChild(count);
        }
        entry.appendChild(resourceLink(item.name, item.id, 'items'));
        list.appendChild(entry);
    }
    return list;
}

/**
 * @param {*} specialization
 */
function specializationSection(specialization) {
    const section = document.createElement('section');
    section.className = 'profession-specialization';

    const title = document.createElement('h2');
    title.textContent = specialization.name === 'Default' ? 'Default specialization' : specialization.name;
    section.appendChild(title);

    const description = document.createElement('p');
    description.textContent = specialization.description;
    section.appendChild(description);

    const skillsHeading = document.createElement('h3');
    skillsHeading.textContent = `Starting skills (${specialization.skills.length})`;
    section.appendChild(skillsHeading);

    const skills = document.createElement('ul');
    skills.className = 'plain-list profession-reference-list';
    for (const skill of specialization.skills) {
        skills.appendChild(skillListItem(skill));
    }
    section.appendChild(skills);

    const heroicHeading = document.createElement('h3');
    heroicHeading.textContent = 'Heroic skill';
    section.appendChild(heroicHeading);

    if (specialization.heroic_skill === null) {
        const magic = document.createElement('p');
        magic.className = 'profession-magic-note';
        magic.textContent = 'This mage school begins with magic instead of a heroic skill.';
        section.appendChild(magic);
    } else {
        const heroic = document.createElement('p');
        heroic.className = 'profession-reference';
        heroic.append(iconFrame(specialization.heroic_skill.icon.name));
        heroic.appendChild(resourceLink(specialization.heroic_skill.name, specialization.heroic_skill.id, 'skills'));
        section.appendChild(heroic);
    }

    const gearHeading = document.createElement('h3');
    gearHeading.textContent = 'Choose one starting-gear package';
    section.appendChild(gearHeading);

    const packages = document.createElement('div');
    packages.className = 'profession-gear-packages';
    for (const [index, items] of specialization.items.entries()) {
        const packageSection = document.createElement('section');
        packageSection.className = 'profession-gear-package';

        const packageHeading = document.createElement('h4');
        packageHeading.textContent = `Package ${index + 1}`;
        packageSection.appendChild(packageHeading);
        packageSection.appendChild(gearPackage(items));
        packages.appendChild(packageSection);
    }
    section.appendChild(packages);

    return section;
}

/**
 * @param {*} profession
 */
function renderItem(profession) {
    const header = document.getElementById('profession-header');
    const specializations = document.getElementById('specializations');
    if (!header || !specializations) {
        throw new Error('No profession details found.');
    }

    const title = document.createElement('h1');
    title.append(iconFrame(profession.icon.name), document.createTextNode(' '), document.createTextNode(profession.name));
    header.appendChild(title);

    const description = document.createElement('p');
    description.className = 'intro';
    description.textContent = profession.description;
    header.appendChild(description);

    const heading = document.createElement('h2');
    heading.textContent = 'Specializations';
    specializations.appendChild(heading);
    for (const specialization of profession.specializations) {
        specializations.appendChild(specializationSection(specialization));
    }
}

async function initialize() {
    try {
        if (page === 'collection') {
            renderCollection(await fetchJson('/professions'));
            return;
        }

        const id = Number(window.location.pathname.split('/').pop());
        if (!Number.isInteger(id) || id < 1) {
            throw new Error('The profession URL has no valid id.');
        }
        renderItem(await fetchJson(`/professions/${id}`));
    } catch (error) {
        reportError(`Could not load professions: ${error instanceof Error ? error.message : String(error)}`);
    }
}

window.addEventListener('load', initialize);
