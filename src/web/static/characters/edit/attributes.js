// © 2026 Antonio Caggiano
// SPDX-License-Identifier: MIT

// @ts-check

import { showStatus, hideStatus } from '../types.js';
/** @typedef {import('../types.js').Character} Character */
/** @typedef {import('../types.js').CharacterAttribute} CharacterAttribute */
/** @typedef {CharacterAttribute & { pending: number}} CharacterAttributeEdit */
/** @typedef {{ attributes: CharacterAttributeEdit[], attribute_points: number }} AttributesDraft */
/** @typedef {import('../types.js').Character & { edit: AttributesDraft }} CharacterAttributesEdit */
/** @typedef {{ data: { character: CharacterAttributesEdit }, update: () => void }} CharacterView */

(() => {
    const list = /** @type {HTMLUListElement} */ (document.querySelector('[data-iter="character.edit.attributes"]'));
    const submitButton = /** @type {HTMLButtonElement} */ (document.getElementById('submit-attributes'));

    /** @type {CharacterAttributesEdit | null} */
    let character = null;
    /** @type {CharacterView | null} */
    let view = null;
    let saving = false;

    document.addEventListener('instanceFetched', onInstanceFetched);
    document.addEventListener('bindingsReady', onBindingsReady);
    document.addEventListener('characterUpdated', onCharacterUpdated);
    list.addEventListener('click', onAttributeButtonClick);
    submitButton.addEventListener('click', onSubmitAttributes);

    /** @param {Event} event */
    function onInstanceFetched(event) {
        setCharacter(/** @type {CharacterAttributesEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {Event} event */
    function onBindingsReady(event) {
        view = /** @type {CharacterView} */ ((/** @type {CustomEvent} */ (event)).detail);
    }

    /** @param {Event} event */
    function onCharacterUpdated(event) {
        setCharacter(/** @type {CharacterAttributesEdit} */ ((/** @type {CustomEvent} */ (event)).detail));
    }

    /** @param {CharacterAttributesEdit} nextCharacter */
    function setCharacter(nextCharacter) {
        character = nextCharacter;
        character.edit = {
            attributes: character.attributes.map((entry) => ({ ...entry, pending: 0 })),
            attribute_points: character.attribute_points,
        };
    }

    /** Refresh bindings after changing a local draft or adopting a server response. */
    function renderAttributes() {
        if (!character || !view) return;
        view.data.character = character;
        view.update();
        for (const button of list.querySelectorAll('button')) button.disabled = saving;
    }

    /** @param {Event} event */
    function onAttributeButtonClick(event) {
        const button = event.target instanceof Element
            ? event.target.closest('[data-action="decrease-attribute"], [data-action="increase-attribute"]')
            : null;
        if (!(button instanceof HTMLButtonElement) || !list.contains(button)) return;

        const attributeId = Number(button.dataset.attributeId);
        if (!Number.isSafeInteger(attributeId)) return;
        addAttribute(attributeId, button.dataset.action === 'increase-attribute' ? 1 : -1);
    }

    /** @param {number} attributeId @param {number} amount */
    function addAttribute(attributeId, amount) {
        if (!character || saving || character.creation_status !== 'attributes') return;
        const attribute = character.edit.attributes.find((entry) => entry.attribute.id === attributeId);
        if (!attribute) return;

        if (amount > 0 && character.edit.attribute_points > 0) {
            attribute.pending += 1;
            character.edit.attribute_points -= 1;
            renderAttributes();
        } else if (amount < 0 && attribute.pending > 0) {
            attribute.pending -= 1;
            character.edit.attribute_points += 1;
            renderAttributes();
        }
    }

    async function onSubmitAttributes() {
        if (!character || saving || character.creation_status !== 'attributes') return;

        const body = character.edit.attributes
            .filter((entry) => entry.pending > 0)
            .map((entry) => ({
                attribute: entry.attribute.id,
                spent: entry.spent + entry.pending,
            }));
        if (body.length === 0) return;

        saving = true;
        submitButton.disabled = true;
        renderAttributes();
        try {
            const response = await fetch(`/characters/${character.id}/attributes`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
            });

            if (!response.ok) {
                showStatus(`Attributes not saved: ${await response.text()}`);
                return;
            }

            const saved = /** @type {CharacterAttributesEdit} */ (await response.json());
            document.dispatchEvent(new CustomEvent('characterUpdated', { detail: saved }));
            renderAttributes();
            document.dispatchEvent(new CustomEvent('characterViewUpdated', { detail: character }));
            hideStatus();
        } catch (error) {
            showStatus(`Attributes not saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally {
            saving = false;
            submitButton.disabled = false;
            renderAttributes();
        }
    }
})();
