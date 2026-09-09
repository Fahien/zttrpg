// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

(() => {

// Training mirrors the attribute step: a click reserves a point locally and a
// submit saves only those new choices. Saved training cannot be refunded.

/** @typedef {{ id: number, attribute: { id: number } | null, kind: { name: string } }} Skill */
/** @typedef {{ skill: Skill, trained: boolean, value: number }} CharacterSkill */
/** @typedef {{ id: number, name: string, description: string, skills: Skill[] }} Specialization */
/** @typedef {{ id: number, trained_skill_count: number }} Age */
/** @typedef {{ specializations: Specialization[] }} Profession */
/** @typedef {{ id: number, attribute_points: number, trained_skill_points: number, creation_complete: boolean, profession: Profession, specialization: Specialization | null, age: Age, skills: CharacterSkill[] }} Character */

/** @type {Character} */
let character = /** @type {Character} */ (/** @type {unknown} */ (null));
/** @type {number | null} */
let specializationId = null;
/** @type {Set<number>} */
const pendingSkillIds = new Set();
let availableTrainingPoints = 0;
/** @type {number | null} */
let minimumProfessionSkills = null;
let submitting = false;
let submitError = '';

const status = /** @type {HTMLElement} */ (document.getElementById('creation-status'));
const creationFieldset = /** @type {HTMLFieldSetElement} */ (document.getElementById('character-creation'));
const specializationOptions = /** @type {HTMLElement} */ (document.getElementById('specialization-options'));
const specializationTemplate = /** @type {HTMLTemplateElement} */ (specializationOptions.querySelector('template'));
const specializationSummary = /** @type {HTMLElement} */ (document.getElementById('selected-specialization'));
const trainedSkillHelp = /** @type {HTMLElement} */ (document.getElementById('trained-skill-help'));
const pointsElement = /** @type {HTMLElement} */ (document.getElementById('trained-skill-points'));
const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-creation'));
const skillSourceList = /** @type {HTMLElement} */ (document.querySelector('[data-list="skills"]'));
const skillGroups = /** @type {HTMLElement} */ (document.getElementById('skill-groups'));
const skillKindTemplate = /** @type {HTMLTemplateElement} */ (document.getElementById('skill-kind-template'));

document.addEventListener('instanceLoaded', onInstanceLoaded);
document.addEventListener('characterUpdated', onCharacterUpdated);
specializationOptions.addEventListener('change', onSpecializationChange);
skillGroups.addEventListener('click', onTrainingButtonClick);
submitButton.addEventListener('click', onSubmit);

/** @param {Event} event */
async function onInstanceLoaded(event) {
    const loaded = /** @type {CustomEvent} */ (event).detail;
    if (!loaded) return;
    adoptCharacter(loaded);
    try {
        minimumProfessionSkills = await fetchConfigValue('profession_skill_minimum');
        submitError = '';
    } catch (error) {
        submitError = `Training rules not loaded: ${error instanceof Error ? error.message : String(error)}`;
    }
    render();
}

/** @param {Event} event Attribute saves replace base chances, so pending training previews update too. */
function onCharacterUpdated(event) {
    const updated = /** @type {Character} */ ((/** @type {CustomEvent} */ (event)).detail);
    if (updated) adoptCharacter(updated);
}

/** @param {Character} nextCharacter */
function adoptCharacter(nextCharacter) {
    character = nextCharacter;
    availableTrainingPoints = character.trained_skill_points;

    const specializations = character.profession.specializations;
    const currentChoiceStillExists = specializations.some((entry) => entry.id === specializationId);
    specializationId = character.specialization?.id ??
        (currentChoiceStillExists ? specializationId : (specializations.length === 1 ? specializations[0].id : null));

    // Training begins only after the persisted attribute pool is empty. A
    // refresh that shows points again invalidates any stale local selection.
    if (!trainingUnlocked()) pendingSkillIds.clear();

    // Attribute saves preserve local choices but may change their previews.
    // A training save clears pending before reaching here.
    for (const id of pendingSkillIds) {
        const entry = character.skills.find((item) => item.skill.id === id);
        if (!entry || entry.skill.attribute === null || entry.trained) pendingSkillIds.delete(id);
    }
    if (character.creation_complete) pendingSkillIds.clear();
    render();
}

function trainingUnlocked() {
    return character.attribute_points === 0;
}

/** @returns {CharacterSkill[]} */
function eligibleSkills() {
    return character.skills.filter((entry) => entry.skill.attribute !== null);
}

/** @returns {Specialization | null} */
function selectedSpecialization() {
    if (specializationId === null) return null;
    return character.profession.specializations.find((entry) => entry.id === specializationId) ?? null;
}

/** The data's Default specialization supplies rules without being a player choice. */
/** @param {Specialization} specialization */
function isDefaultSpecialization(specialization) {
    return specialization.name === 'Default';
}

/** @returns {Set<number>} */
function selectedSpecializationSkillIds() {
    const specialization = selectedSpecialization();
    return new Set((specialization?.skills ?? [])
        .filter((skill) => skill.attribute !== null)
        .map((skill) => skill.id));
}

function trainingState() {
    const specializationSkills = selectedSpecializationSkillIds();
    let savedTotal = 0;
    let savedSpecialization = 0;
    for (const entry of eligibleSkills()) {
        if (!entry.trained) continue;
        savedTotal += 1;
        if (specializationSkills.has(entry.skill.id)) savedSpecialization += 1;
    }
    let pendingSpecialization = 0;
    for (const id of pendingSkillIds) {
        if (specializationSkills.has(id)) pendingSpecialization += 1;
    }
    const selectedTotal = savedTotal + pendingSkillIds.size;
    const selectedProfession = savedSpecialization + pendingSpecialization;
    return {
        requiredTotal: character.age.trained_skill_count,
        savedTotal,
        savedSpecialization,
        selectedTotal,
        selectedProfession,
        remainingTotal: Math.max(0, character.age.trained_skill_count - selectedTotal),
        remainingProfession: Math.max(0, (minimumProfessionSkills ?? 0) - selectedProfession),
    };
}

/**
 * Reads a numeric rule from the generic configuration resource.
 * @param {string} name
 */
async function fetchConfigValue(name) {
    const response = await fetch('/configs', { headers: { 'Accept': 'application/json' } });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    const configs = /** @type {{ name: string, value: string }[]} */ (await response.json());
    const config = configs.find((entry) => entry.name === name);
    const value = Number(config?.value);
    if (!config || !Number.isSafeInteger(value) || value < 0) throw new Error(`invalid config: ${name}`);
    return value;
}

/** @param {Event} event */
function onSpecializationChange(event) {
    const target = event.target;
    if (!(target instanceof HTMLInputElement) || target.name !== 'specialization') return;
    const id = Number(target.value);
    if (!Number.isSafeInteger(id)) return;

    // Before a save, choosing another path also discards its unsaved skills.
    availableTrainingPoints += pendingSkillIds.size;
    specializationId = id;
    pendingSkillIds.clear();
    submitError = '';
    render();
}

/** @param {Event} event */
function onTrainingButtonClick(event) {
    if (!(event.target instanceof Element)) return;
    const button = event.target.closest('button[data-action]');
    if (!(button instanceof HTMLButtonElement)) return;
    const id = Number(button.dataset.skillId);
    if (!Number.isSafeInteger(id)) return;

    if (!trainingUnlocked()) return;
    if (button.dataset.action === 'increase-training') {
        addPendingSkill(id);
    } else if (button.dataset.action === 'decrease-training') {
        pendingSkillIds.delete(id);
        availableTrainingPoints += 1;
    }
    render();
}

/** @param {number} id */
function addPendingSkill(id) {
    if (!trainingUnlocked()) return;
    const entry = character.skills.find((item) => item.skill.id === id);
    if (!entry || entry.skill.attribute === null || entry.trained || pendingSkillIds.has(id)) return;
    if (availableTrainingPoints <= 0 || selectedSpecialization() === null) return;

    const state = trainingState();
    const specializationSkills = selectedSpecializationSkillIds();
    if (!canAddSkill(specializationSkills.has(id), state)) return;

    pendingSkillIds.add(id);
    availableTrainingPoints -= 1;
}

function render() {
    if (!character) return;
    groupSkills();
    renderSheetSkills();
    renderTrainingNotice();
    renderSpecializationSummary();
    renderSpecializations();
    if (character.creation_complete) {
        submitButton.hidden = true;
        hideTrainingControls();
        status.hidden = true;
        return;
    }

    if (trainingUnlocked() && minimumProfessionSkills !== null) {
        submitButton.hidden = false;
        renderSkills();
    } else {
        submitButton.hidden = true;
        hideTrainingControls();
    }
    renderStatus();
}

function renderSpecializations() {
    const specializations = character.profession.specializations;
    const hasChoices = specializations.some((entry) => !isDefaultSpecialization(entry));
    // A radio choice is only a draft until creation completes on the server.
    // Keep it available while the player assigns and confirms training points.
    creationFieldset.hidden = character.creation_complete || !hasChoices;
    const needsChoice = !creationFieldset.hidden && specializationId === null;
    for (const element of document.querySelectorAll('[data-requires-specialization]')) {
        if (element instanceof HTMLElement) element.hidden = !needsChoice;
    }
    if (creationFieldset.hidden) return;

    for (const option of specializationOptions.querySelectorAll('[data-specialization-option]')) option.remove();

    for (const specialization of specializations) {
        const option = /** @type {DocumentFragment} */ (specializationTemplate.content.cloneNode(true));
        const li = /** @type {HTMLElement} */ (option.querySelector('[data-specialization-option]'));
        const input = /** @type {HTMLInputElement} */ (li.querySelector('input[name="specialization"]'));
        const name = /** @type {HTMLElement} */ (li.querySelector('[data-specialization-name]'));
        const description = /** @type {HTMLElement} */ (li.querySelector('[data-specialization-description]'));
        input.value = String(specialization.id);
        input.checked = specialization.id === specializationId;
        input.disabled = submitting;
        name.textContent = ` ${specialization.name}`;
        if (specialization.description) {
            description.textContent = ` ${specialization.description}`;
            description.hidden = false;
        }
        specializationOptions.append(option);
    }
}

function renderSpecializationSummary() {
    const specialization = selectedSpecialization();
    specializationSummary.hidden = specialization === null || isDefaultSpecialization(specialization);
    if (specialization !== null) {
        const name = specializationSummary.querySelector('span');
        if (name) name.textContent = specialization.name;
    }
}

function renderTrainingNotice() {
    pointsElement.textContent = String(availableTrainingPoints);
    for (const element of document.querySelectorAll('[data-requires-training-points]')) {
        if (element instanceof HTMLElement) element.hidden = availableTrainingPoints <= 0 || minimumProfessionSkills === null;
    }
}

function groupSkills() {
    // instance.js expands this source list once. Once its rows have moved into
    // their groups, later character updates only refresh those same rows.
    if (!skillSourceList.querySelector('[data-skill-id]')) return;

    /** @type {Map<string, HTMLUListElement>} */
    const listsByKind = new Map();
    skillGroups.replaceChildren();
    for (const entry of character.skills) {
        const row = findSkillRow(entry.skill.id);
        if (!row) continue;
        const kind = entry.skill.kind.name;
        let list = listsByKind.get(kind);
        if (!list) {
            const group = /** @type {DocumentFragment} */ (skillKindTemplate.content.cloneNode(true));
            const section = /** @type {HTMLElement} */ (group.querySelector('.skill-kind'));
            const heading = /** @type {HTMLElement} */ (section.querySelector('[data-skill-kind]'));
            list = /** @type {HTMLUListElement} */ (section.querySelector('ul'));
            heading.textContent = kind;
            listsByKind.set(kind, list);
            skillGroups.append(group);
        }
        list.append(row);
    }
}

/** @param {number} id */
function findSkillRow(id) {
    return skillGroups.querySelector(`[data-skill-id="${id}"]`) ??
        skillSourceList.querySelector(`[data-skill-id="${id}"]`);
}

function renderSkills() {
    const specializationSkillIds = selectedSpecializationSkillIds();
    const state = trainingState();
    const hasSpecialization = selectedSpecialization() !== null;
    for (const entry of character.skills) {
        const row = findSkillRow(entry.skill.id);
        if (!row) continue;
        const inSpecialization = specializationSkillIds.has(entry.skill.id);
        const specializationLabel = row.querySelector('[data-specialization-skill]');
        if (specializationLabel instanceof HTMLElement) {
            specializationLabel.hidden = !inSpecialization;
        }
        const trainingLabel = row.querySelector('[data-training-state]');
        const plus = row.querySelector('button[data-action="increase-training"]');
        const minus = row.querySelector('button[data-action="decrease-training"]');
        if (entry.skill.attribute === null) {
            if (trainingLabel instanceof HTMLElement) trainingLabel.hidden = true;
            if (plus instanceof HTMLButtonElement) plus.hidden = true;
            if (minus instanceof HTMLButtonElement) minus.hidden = true;
            continue;
        }

        const pending = pendingSkillIds.has(entry.skill.id);
        const saved = entry.trained;
        if (trainingLabel instanceof HTMLElement) {
            trainingLabel.hidden = !saved;
            trainingLabel.textContent = saved ? 'saved' : '';
        }
        if (minus instanceof HTMLButtonElement) {
            minus.hidden = !pending;
            minus.disabled = submitting;
            minus.dataset.skillId = String(entry.skill.id);
        }
        if (plus instanceof HTMLButtonElement) {
            plus.hidden = saved || pending || !hasSpecialization || availableTrainingPoints <= 0;
            plus.disabled = !canAddSkill(inSpecialization, state);
            plus.dataset.skillId = String(entry.skill.id);
        }
    }
}

/** @param {boolean} inProfession @param {ReturnType<typeof trainingState>} state @param {number} minimum */
function hasRoomForProfessionMinimum(inProfession, state, minimum) {
    const nextProfession = state.selectedProfession + (inProfession ? 1 : 0);
    const nextTotal = state.selectedTotal + 1;
    const remainingSlots = state.requiredTotal - nextTotal;
    const remainingProfession = Math.max(0, minimum - nextProfession);
    return nextTotal <= state.requiredTotal && remainingSlots >= remainingProfession;
}

/** @param {boolean} inSpecialization @param {ReturnType<typeof trainingState>} state */
function canAddSkill(inSpecialization, state) {
    if (!trainingUnlocked() || minimumProfessionSkills === null || submitting || availableTrainingPoints <= 0 || selectedSpecialization() === null) return false;
    return hasRoomForProfessionMinimum(inSpecialization, state, minimumProfessionSkills);
}

function renderStatus() {
    const specialization = selectedSpecialization();
    const state = trainingState();
    trainedSkillHelp.textContent = !trainingUnlocked()
        ? `Spend all ${character.attribute_points} remaining attribute point${character.attribute_points === 1 ? '' : 's'} before selecting training skills.`
        : specialization === null
        ? ''
        : `${state.remainingProfession} more profession skill${state.remainingProfession === 1 ? '' : 's'} required; ${state.remainingTotal} training point${state.remainingTotal === 1 ? '' : 's'} remaining.`;
    status.textContent = submitError;
    status.classList.toggle('error', submitError.length > 0);
    status.hidden = submitError.length === 0;
    submitButton.disabled = pendingSkillIds.size === 0 || specialization === null || submitting;
}

function hideTrainingControls() {
    for (const element of skillGroups.querySelectorAll('[data-specialization-skill], [data-training-state], button[data-action="increase-training"], button[data-action="decrease-training"]')) {
        if (element instanceof HTMLElement) element.hidden = true;
    }
}

function renderSheetSkills() {
    for (const entry of character.skills) {
        const row = findSkillRow(entry.skill.id);
        if (!row) continue;
        const value = row.querySelector('[data-field="value"]');
        if (value) value.textContent = String(pendingSkillIds.has(entry.skill.id) ? entry.value * 2 : entry.value);
    }
}

async function onSubmit() {
    const specialization = selectedSpecialization();
    if (!trainingUnlocked() || submitting || specialization === null || pendingSkillIds.size === 0) return;
    submitting = true;
    submitError = '';
    render();
    try {
        const response = await fetch(`/characters/${character.id}/creation`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ specialization: specialization.id, skills: [...pendingSkillIds] }),
        });
        if (!response.ok) throw new Error(await response.text());
        pendingSkillIds.clear();
        const saved = /** @type {Character} */ (await response.json());
        adoptCharacter(saved);
        document.dispatchEvent(new CustomEvent('characterUpdated', { detail: saved }));
    } catch (error) {
        submitError = `Training not saved: ${error instanceof Error ? error.message : String(error)}`;
    } finally {
        submitting = false;
        render();
    }
}

})();
