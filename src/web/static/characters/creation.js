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

const picker = /** @type {HTMLElement} */ (document.getElementById('creation-picker'));
const status = /** @type {HTMLElement} */ (document.getElementById('creation-status'));
const specializationOptions = /** @type {HTMLElement} */ (document.getElementById('specialization-options'));
const specializationHelp = /** @type {HTMLElement} */ (document.getElementById('specialization-help'));
const trainedSkillHelp = /** @type {HTMLElement} */ (document.getElementById('trained-skill-help'));
const pointsElement = /** @type {HTMLElement} */ (document.getElementById('trained-skill-points'));
const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-creation'));
const skillList = /** @type {HTMLElement} */ (document.querySelector('[data-list="skills"]'));

document.addEventListener('instanceLoaded', onInstanceLoaded);
document.addEventListener('characterUpdated', onCharacterUpdated);
specializationOptions.addEventListener('change', onSpecializationChange);
skillList.addEventListener('click', onTrainingButtonClick);
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
    renderSheetSkills();
    if (character.creation_complete) {
        picker.hidden = true;
        submitButton.hidden = true;
        hideTrainingControls();
        const name = character.specialization?.name;
        status.textContent = name ? `Character creation complete: ${name}.` : 'Character creation complete.';
        status.classList.remove('error');
        return;
    }

    picker.hidden = false;
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
    specializationOptions.replaceChildren();
    const specializations = character.profession.specializations;
    const singleton = specializations.length === 1;
    const locked = trainingState().savedTotal > 0;
    specializationHelp.textContent = singleton
        ? 'This profession has one specialization, selected automatically.'
        : locked
            ? 'Specialization is locked after training points have been saved.'
            : 'Choose a specialization before training skills.';

    for (const specialization of specializations) {
        const li = document.createElement('li');
        const label = document.createElement('label');
        const input = document.createElement('input');
        input.type = 'radio';
        input.name = 'specialization';
        input.value = String(specialization.id);
        input.checked = specialization.id === specializationId;
        input.disabled = singleton || locked || submitting;
        label.append(input, ` ${specialization.name}`);
        li.append(label);
        if (specialization.description) {
            const description = document.createElement('small');
            description.textContent = ` ${specialization.description}`;
            li.append(description);
        }
        specializationOptions.append(li);
    }
}

function renderSkills() {
    const specializationSkillIds = selectedSpecializationSkillIds();
    const state = trainingState();
    const hasSpecialization = selectedSpecialization() !== null;
    for (const entry of character.skills) {
        const row = skillList.querySelector(`[data-skill-id="${entry.skill.id}"]`);
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
    pointsElement.textContent = String(availableTrainingPoints);
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
    submitButton.disabled = pendingSkillIds.size === 0 || specialization === null || submitting;
}

function hideTrainingControls() {
    for (const element of skillList.querySelectorAll('[data-specialization-skill], [data-training-state], button[data-action="increase-training"], button[data-action="decrease-training"]')) {
        if (element instanceof HTMLElement) element.hidden = true;
    }
}

function renderSheetSkills() {
    for (const entry of character.skills) {
        const row = document.querySelector(`[data-list="skills"] [data-skill-id="${entry.skill.id}"]`);
        if (!row) continue;
        const value = row.querySelector('[data-field="value"]');
        if (value) value.textContent = String(entry.value);
        const baseChance = row.querySelector('[data-base-chance]');
        if (baseChance instanceof HTMLElement) {
            baseChance.hidden = entry.base_chance === null;
            baseChance.textContent = entry.base_chance === null ? '' : `(Base chance: ${entry.base_chance})`;
        }
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
