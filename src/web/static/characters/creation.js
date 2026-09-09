// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

(() => {

// Training mirrors the attribute step: a click reserves a point locally and a
// submit saves only those new choices. Saved training cannot be refunded.

/** @type {*} */
let character = null;
/** @type {number | null} */
let specializationId = null;
const pendingSkillIds = new Set();
let availableTrainingPoints = 0;
let submitting = false;
let submitError = '';

const status = /** @type {HTMLElement} */ (document.getElementById('creation-status'));
const creationFieldset = /** @type {HTMLFieldSetElement} */ (document.getElementById('character-creation'));
const specializationOptions = /** @type {HTMLElement} */ (document.getElementById('specialization-options'));
const specializationHelp = /** @type {HTMLElement} */ (document.getElementById('specialization-help'));
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
function onInstanceLoaded(event) {
    const loaded = /** @type {CustomEvent} */ (event).detail;
    if (loaded) adoptCharacter(loaded);
}

/** Attribute saves replace base chances, so pending training previews update too. */
function onCharacterUpdated(event) {
    const updated = /** @type {CustomEvent} */ (event).detail;
    if (updated) adoptCharacter(updated);
}

/** @param {*} nextCharacter */
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
        if (!entry || entry.base_chance === null || entry.value > 0) pendingSkillIds.delete(id);
    }
    if (character.creation_complete) pendingSkillIds.clear();
    render();
}

function trainingUnlocked() {
    return character.attribute_points === 0;
}

/** @returns {any[]} */
function eligibleSkills() {
    return character.skills.filter((entry) => entry.base_chance !== null);
}

/** @returns {any | null} */
function selectedSpecialization() {
    if (specializationId === null) return null;
    return character.profession.specializations.find((entry) => entry.id === specializationId) ?? null;
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
        if (entry.value <= 0) continue;
        savedTotal += 1;
        if (specializationSkills.has(entry.skill.id)) savedSpecialization += 1;
    }
    let pendingSpecialization = 0;
    for (const id of pendingSkillIds) {
        if (specializationSkills.has(id)) pendingSpecialization += 1;
    }
    return {
        requiredTotal: character.age.trained_skill_count,
        savedTotal,
        savedSpecialization,
        selectedTotal: savedTotal + pendingSkillIds.size,
        selectedSpecialization: savedSpecialization + pendingSpecialization,
        selectedOther: savedTotal + pendingSkillIds.size - savedSpecialization - pendingSpecialization,
    };
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
    if (!entry || entry.base_chance === null || entry.value > 0 || pendingSkillIds.has(id)) return;
    if (availableTrainingPoints <= 0 || selectedSpecialization() === null) return;

    const state = trainingState();
    const specializationSkills = selectedSpecializationSkillIds();
    const nextSpecialization = state.selectedSpecialization + (specializationSkills.has(id) ? 1 : 0);
    const nextTotal = state.selectedTotal + 1;
    const nextOther = state.selectedOther + (specializationSkills.has(id) ? 0 : 1);
    if (nextSpecialization > 6 || nextOther > state.requiredTotal - 6 || nextTotal > state.requiredTotal) return;
    // The final point must leave the exact-six requirement true.
    if (nextTotal === state.requiredTotal && nextSpecialization !== 6) return;

    pendingSkillIds.add(id);
    availableTrainingPoints -= 1;
}

function render() {
    if (!character) return;
    groupSkills();
    renderSheetSkills();
    renderTrainingNotice();
    renderSpecializationSummary();
    if (character.creation_complete) {
        submitButton.hidden = true;
        hideTrainingControls();
        const name = character.specialization?.name;
        status.textContent = name ? `Character creation complete: ${name}.` : 'Character creation complete.';
        status.hidden = false;
        status.classList.remove('error');
        return;
    }

    renderSpecializations();
    if (trainingUnlocked()) {
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
    const locked = trainingState().savedTotal > 0;
    creationFieldset.hidden = specializations.length === 0 || specializationId !== null;
    if (creationFieldset.hidden) return;

    specializationHelp.textContent = locked
        ? 'Specialization is locked after training points have been saved.'
        : 'Choose a specialization before training skills.';
    for (const option of specializationOptions.querySelectorAll('[data-specialization-option]')) option.remove();

    for (const specialization of specializations) {
        const option = specializationTemplate.content.cloneNode(true);
        const li = /** @type {HTMLElement} */ (option.querySelector('[data-specialization-option]'));
        const input = /** @type {HTMLInputElement} */ (li.querySelector('input[name="specialization"]'));
        const name = /** @type {HTMLElement} */ (li.querySelector('[data-specialization-name]'));
        const description = /** @type {HTMLElement} */ (li.querySelector('[data-specialization-description]'));
        input.value = String(specialization.id);
        input.checked = specialization.id === specializationId;
        input.disabled = locked || submitting;
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
    specializationSummary.hidden = specialization === null;
    if (specialization !== null) {
        const name = specializationSummary.querySelector('span');
        if (name) name.textContent = specialization.name;
    }
}

function renderTrainingNotice() {
    pointsElement.textContent = String(availableTrainingPoints);
    for (const element of document.querySelectorAll('[data-requires-training-points]')) {
        if (element instanceof HTMLElement) element.hidden = availableTrainingPoints <= 0;
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
            const group = skillKindTemplate.content.cloneNode(true);
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
        if (entry.base_chance === null) {
            if (trainingLabel instanceof HTMLElement) trainingLabel.hidden = true;
            if (plus instanceof HTMLButtonElement) plus.hidden = true;
            if (minus instanceof HTMLButtonElement) minus.hidden = true;
            continue;
        }

        const pending = pendingSkillIds.has(entry.skill.id);
        const saved = entry.value > 0;
        if (trainingLabel instanceof HTMLElement) {
            trainingLabel.hidden = !saved && !pending;
            trainingLabel.textContent = saved ? 'saved' : 'pending';
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

/** @param {boolean} inSpecialization @param {ReturnType<typeof trainingState>} state */
function canAddSkill(inSpecialization, state) {
    if (!trainingUnlocked() || submitting || availableTrainingPoints <= 0 || selectedSpecialization() === null) return false;
    const nextSpecialization = state.selectedSpecialization + (inSpecialization ? 1 : 0);
    const nextTotal = state.selectedTotal + 1;
    const nextOther = state.selectedOther + (inSpecialization ? 0 : 1);
    if (nextSpecialization > 6 || nextOther > state.requiredTotal - 6 || nextTotal > state.requiredTotal) return false;
    return nextTotal !== state.requiredTotal || nextSpecialization === 6;
}

function renderStatus() {
    const specialization = selectedSpecialization();
    const state = trainingState();
    trainedSkillHelp.textContent = !trainingUnlocked()
        ? `Spend all ${character.attribute_points} remaining attribute point${character.attribute_points === 1 ? '' : 's'} before selecting training skills.`
        : specialization === null
        ? `Choose a specialization, then spend ${state.requiredTotal} training points.`
        : `${state.selectedSpecialization}/6 specialization skills trained; ${state.selectedTotal}/${state.requiredTotal} training points assigned.`;
    status.textContent = submitError || (!trainingUnlocked()
        ? 'Training unlocks after all attribute points are saved.'
        : availableTrainingPoints === 0
        ? 'Training is complete. Spend the remaining attribute points to complete character creation.'
        : pendingSkillIds.size > 0
            ? `${pendingSkillIds.size} training point${pendingSkillIds.size === 1 ? '' : 's'} pending save.`
            : 'Training points pending.');
    status.classList.toggle('error', submitError.length > 0);
    status.hidden = false;
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
        if (value) value.textContent = String(entry.value);
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
        const saved = await response.json();
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
