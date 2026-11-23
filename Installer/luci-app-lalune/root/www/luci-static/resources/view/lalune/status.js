'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

const getStatus = rpc.declare({ object: 'lalune', method: 'status' });
const getStats = rpc.declare({ object: 'lalune', method: 'stats' });
const getConfigs = rpc.declare({ object: 'lalune', method: 'configs' });
const getSelected = rpc.declare({ object: 'lalune', method: 'selected' });
const getProtocols = rpc.declare({ object: 'lalune', method: 'protocols' });
const getLogs = rpc.declare({ object: 'lalune', method: 'logs' });
const connectVpn = rpc.declare({ object: 'lalune', method: 'connect' });
const disconnectVpn = rpc.declare({ object: 'lalune', method: 'disconnect' });
const reconnectVpn = rpc.declare({ object: 'lalune', method: 'reconnect' });
const selectProfile = rpc.declare({ object: 'lalune', method: 'select', params: [ 'id' ] });
const createProfile = rpc.declare({ object: 'lalune', method: 'create', params: [ 'body' ] });
const deleteProfile = rpc.declare({ object: 'lalune', method: 'delete', params: [ 'id' ] });

function bytes(value) {
    let n = Math.max(0, Number(value) || 0);
    const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n.toFixed(0) : n.toFixed(2)) + ' ' + units[i];
}

function rate(value) {
    return bytes(value) + '/s';
}

function notify(message, type) {
    ui.addNotification(null, E('p', {}, message), type || 'info');
}

return view.extend({
    load: function() {
        return Promise.all([
            getStatus(), getStats(), getConfigs(), getSelected(), getProtocols()
        ]);
    },

    render: function(initial) {
        let profiles = initial[2] && initial[2].items || [];
        let selected = initial[3] || {};
        let protocols = initial[4] && initial[4].items || [];
        let selectedId = selected.id || null;
        let busy = false;

        const stateText = E('span', { 'class': 'label' }, _('Loading…'));
        const uptimeText = E('span', {}, '');
        const rxText = E('span', {}, '—');
        const txText = E('span', {}, '—');
        const rxRateText = E('span', {}, '—');
        const txRateText = E('span', {}, '—');
        const workerText = E('span', {}, '—');
        const profileSelect = E('select', { 'class': 'cbi-input-select' });
        const nameInput = E('input', { 'class': 'cbi-input-text', type: 'text', placeholder: _('Profile name') });
        const linkInput = E('textarea', { 'class': 'cbi-input-textarea', rows: '3', placeholder: _('Paste a CSQTT / CSQTTR profile link') });
        const logBox = E('pre', { 'class': 'cbi-input-text', style: 'max-height: 22rem; overflow:auto; white-space:pre-wrap' }, _('Press “Refresh logs” to load recent messages.'));
        const messageBox = E('p', { 'class': 'alert-message', hidden: true }, '');

        function showMessage(text, isError) {
            messageBox.hidden = !text;
            messageBox.textContent = text || '';
            messageBox.className = isError ? 'alert-message error' : 'alert-message info';
        }

        function renderProfiles() {
            const options = [ E('option', { value: '' }, _('Select profile')) ];
            profiles.forEach((profile) => {
                const label = (profile.name || profile.peer || ('#' + profile.id)) + ' · ' + profile.protocol;
                options.push(E('option', { value: String(profile.id) }, label));
            });
            profileSelect.replaceChildren(...options);
            profileSelect.value = selectedId ? String(selectedId) : '';
        }

        async function refreshStatus() {
            try {
                const result = await Promise.all([ getStatus(), getStats() ]);
                const status = result[0] || {};
                const stats = result[1] || {};
                if (status.error || stats.error)
                    throw new Error(status.error || stats.error);
                const state = status.connected ? 'connected' : (status.state || 'disconnected');
                stateText.textContent = state === 'connected' ? _('Connected') :
                    state === 'connecting' ? _('Connecting…') : _('Disconnected');
                stateText.className = 'label ' + (state === 'connected' ? 'success' : state === 'connecting' ? 'warning' : '');
                uptimeText.textContent = state === 'connected' ? (Number(status.uptimeSec || 0) + ' s') : '';
                rxText.textContent = bytes(stats.rxBytes);
                txText.textContent = bytes(stats.txBytes);
                rxRateText.textContent = rate(stats.rxRate);
                txRateText.textContent = rate(stats.txRate);
                workerText.textContent = String(stats.activeSessions || 0);
            } catch (error) {
                stateText.textContent = _('API unavailable');
                stateText.className = 'label warning';
            }
        }

        async function refreshProfiles() {
            const result = await Promise.all([ getConfigs(), getSelected() ]);
            if (result[0] && result[0].error)
                throw new Error(result[0].error);
            profiles = result[0] && result[0].items || [];
            selected = result[1] || {};
            selectedId = selected.id || null;
            renderProfiles();
        }

        async function runAction(action, successText) {
            if (busy) return;
            busy = true;
            showMessage(_('Working…'), false);
            try {
                const result = await action();
                if (result && result.error) throw new Error(result.error);
                showMessage(successText, false);
                await refreshProfiles();
                await refreshStatus();
            } catch (error) {
                showMessage(String(error.message || error), true);
            } finally {
                busy = false;
            }
        }

        profileSelect.addEventListener('change', () => {
            const id = Number(profileSelect.value);
            if (!id) return;
            runAction(() => selectProfile(id), _('Selected profile saved.'));
        });

        const connectButton = E('button', { 'class': 'btn cbi-button cbi-button-action' }, _('Connect'));
        connectButton.addEventListener('click', () => runAction(connectVpn, _('Connect requested.')));
        const disconnectButton = E('button', { 'class': 'btn cbi-button' }, _('Disconnect'));
        disconnectButton.addEventListener('click', () => runAction(disconnectVpn, _('VPN disconnected.')));
        const reconnectButton = E('button', { 'class': 'btn cbi-button' }, _('Reconnect'));
        reconnectButton.addEventListener('click', () => runAction(reconnectVpn, _('Reconnect requested.')));

        const addButton = E('button', { 'class': 'btn cbi-button cbi-button-add' }, _('Add profile'));
        addButton.addEventListener('click', () => runAction(async () => {
            const link = linkInput.value.trim();
            if (!link) throw new Error(_('Paste a profile link first.'));
            const protocol = protocols.find((item) => item.id === 'CSQTT') ? 'CSQTT' : (protocols[0] && protocols[0].id) || 'CSQTT';
            const body = JSON.stringify({ protocol: protocol, link: link, name: nameInput.value.trim() });
            const created = await createProfile(body);
            if (created && created.id) {
                await selectProfile(Number(created.id));
                linkInput.value = '';
                nameInput.value = '';
            }
            return created;
        }, _('Profile added and selected.')));

        const deleteButton = E('button', { 'class': 'btn cbi-button cbi-button-remove' }, _('Delete selected'));
        deleteButton.addEventListener('click', () => {
            if (!selectedId || !confirm(_('Delete the selected profile?'))) return;
            runAction(() => deleteProfile(Number(selectedId)), _('Profile deleted.'));
        });

        const logsButton = E('button', { 'class': 'btn cbi-button' }, _('Refresh logs'));
        logsButton.addEventListener('click', async () => {
            try {
                const result = await getLogs();
                logBox.textContent = (result.items || []).join('\n') || _('Log is empty.');
            } catch (error) {
                logBox.textContent = String(error.message || error);
            }
        });

        const page = E('div', { 'class': 'cbi-map' }, [
            E('h2', {}, _('LaLune VPN')),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Connection')),
                E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Status')), E('div', { 'class': 'cbi-value-field' }, [ stateText, uptimeText ]) ]),
                E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Selected profile')), E('div', { 'class': 'cbi-value-field' }, profileSelect) ]),
                E('div', { 'class': 'cbi-page-actions' }, [ connectButton, disconnectButton, reconnectButton, deleteButton ]),
                messageBox
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Traffic statistics')),
                E('div', { 'class': 'table' }, [
                    E('div', { 'class': 'tr table-titles' }, [ E('div', { 'class': 'th' }, _('Metric')), E('div', { 'class': 'th' }, _('Received')), E('div', { 'class': 'th' }, _('Sent')) ]),
                    E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td' }, _('Total')), E('div', { 'class': 'td' }, rxText), E('div', { 'class': 'td' }, txText) ]),
                    E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td' }, _('Speed')), E('div', { 'class': 'td' }, rxRateText), E('div', { 'class': 'td' }, txRateText) ]),
                    E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td' }, _('Active sessions')), E('div', { 'class': 'td', colspan: '2' }, workerText) ])
                ])
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Add a profile')),
                E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Name')), E('div', { 'class': 'cbi-value-field' }, nameInput) ]),
                E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Connection link')), E('div', { 'class': 'cbi-value-field' }, linkInput) ]),
                E('div', { 'class': 'cbi-page-actions' }, addButton)
            ]),
            E('div', { 'class': 'cbi-section' }, [
                E('h3', {}, _('Recent logs')),
                logsButton,
                logBox
            ])
        ]);

        renderProfiles();
        refreshStatus();
        poll.add(refreshStatus, 3);
        return page;
    }
});
