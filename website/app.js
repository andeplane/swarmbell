const initialAgents = [
  { id: 'atlas', harness: 'claude', project: 'Little Atlas', title: 'Choose a sharing default', state: 'needs', age: '2 min', usage: '', detail: 'The trip-sharing flow is ready. Should shared trips include saved places by default, or just the itinerary?', question: true },
  { id: 'sunday', harness: 'codex', project: 'Sunday Studio', title: 'Build the invite flow', state: 'working', age: '6 min', usage: '81.4k tokens', detail: 'Adding invite links and checking the first-time experience. In the real app, a supported conversation opens in its original harness.' },
  { id: 'orchard', harness: 'cursor', project: 'Orchard', title: 'Finish the settings screen', state: 'working', age: '4 min', usage: '', detail: 'A lifecycle hook reports that this example Cursor session is working. Native approvals and exact chat activation are not fully covered in the current app.' },
  { id: 'luma', harness: 'codex', project: 'Luma Notes', title: 'Tidy the editor toolbar', state: 'working', age: '9 min', usage: '42.8k tokens', detail: 'Refining keyboard shortcuts and checking the toolbar at smaller window sizes. Token values here are illustrative, just like the rest of this demo.' },
  { id: 'welcome', harness: 'claude', project: 'Sunday Studio', title: 'Add the welcome illustration', state: 'finished', age: '12 min', usage: '', detail: 'This example task is finished. Finished and idle sessions remain separate from the active count.' },
];
const harnessNames = { codex: 'Codex', claude: 'Claude Code', cursor: 'Cursor' };
let agents = structuredClone(initialAgents);
let stateFilter = 'all';
let harnessFilter = 'all';
let selectedId = null;
let switcherIndex = 0;
let currentView = 'agents';
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const dialog = $('#switcher-dialog');
const escapeHTML = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const iconPaths = {
  claude: '<path d="M12 2v20M2 12h20M5 5l14 14M5 19 19 5M8 2l8 20M2 8l20 8M2 16l20-8M8 22l8-20"/>',
  codex: '<path d="m12 3 7.8 4.5v9L12 21l-7.8-4.5v-9L12 3Zm0 0v8.8m7.8-4.3-7.8 4.3m0 0-7.8-4.3m7.8 4.3V21m0-9.2 7.8 4.7m-7.8-4.7-7.8 4.7"/>',
  cursor: '<path d="m4 3 16 9-8 2-3 7L4 3Zm0 0 8 11m0 0 5 6"/>',
};
function harnessIcon(harness) { return `<span class="harness-logo ${harness}" aria-hidden="true"><svg viewBox="0 0 24 24">${iconPaths[harness]}</svg></span>`; }
$$('.harness-line .harness-logo').forEach((el) => { const type = Object.keys(harnessNames).find((name) => el.classList.contains(name)); el.innerHTML = `<svg viewBox="0 0 24 24">${iconPaths[type]}</svg>`; });
function activeCount(list) { return list.filter((agent) => agent.state === 'working' || agent.state === 'needs').length; }
function needsCount(list) { return list.filter((agent) => agent.state === 'needs').length; }
function announce(message) { $('#demo-announcement').textContent = message; }
function filteredAgents() { return agents.filter((agent) => (harnessFilter === 'all' || agent.harness === harnessFilter) && (stateFilter === 'all' || agent.state === stateFilter)); }
function renderAgents() {
  const scoped = agents.filter((agent) => harnessFilter === 'all' || agent.harness === harnessFilter);
  $('#counter-active').textContent = activeCount(agents);
  $('#counter-needs').textContent = needsCount(agents);
  $('#sidebar-needs').textContent = needsCount(agents);
  $('#filter-needs').textContent = needsCount(scoped);
  $('#agent-summary').textContent = `${activeCount(scoped)} active · ${needsCount(scoped)} ${needsCount(scoped) === 1 ? 'needs' : 'need'} you`;
  $('#menu-counter').setAttribute('aria-label', `Open example agent list: ${activeCount(agents)} active, ${needsCount(agents)} need you`);
  const list = filteredAgents();
  const groups = [['needs', 'Needs you'], ['working', 'Working'], ['finished', 'Recently finished']];
  $('#agent-list').innerHTML = groups.map(([state, label]) => {
    const members = list.filter((agent) => agent.state === state);
    if (!members.length) return '';
    return `<p class="agent-group-label ${state === 'working' ? 'working-label' : ''}">${label} (${members.length})</p>` + members.map((agent) => `<button class="agent-row ${agent.id === selectedId ? 'selected' : ''}" data-agent="${agent.id}" aria-expanded="${agent.id === selectedId}" aria-controls="agent-detail">${harnessIcon(agent.harness)}<span class="agent-copy"><strong>${escapeHTML(agent.title)}</strong><span>${harnessNames[agent.harness]} · ${escapeHTML(agent.project)}</span></span><span class="agent-status ${agent.state}">${agent.state === 'needs' ? 'Needs you' : agent.state === 'working' ? 'Working' : 'Finished'}<small>${agent.usage || agent.age}</small></span></button>`).join('');
  }).join('') || '<p class="empty-agents">No example agents here.<br>Try another harness or show all agents.</p>';
  $$('[data-agent]').forEach((button) => button.addEventListener('click', () => showDetail(button.dataset.agent)));
  if (!list.some((agent) => agent.id === selectedId)) selectedId = null;
  renderDetail();
}
function renderDetail() {
  const agent = agents.find((item) => item.id === selectedId);
  const detail = $('#agent-detail');
  detail.hidden = !agent;
  if (!agent) return;
  detail.innerHTML = `<div class="detail-top"><h4>${escapeHTML(agent.project)}</h4><button class="plain-button" id="close-detail" aria-label="Close example agent details">Close</button></div><p>${escapeHTML(agent.detail)}</p>${agent.state === 'needs' ? '<button class="review-demo" id="review-example">Mark as reviewed in demo</button>' : ''}<p class="detail-note">Example interaction only. No real agent is opened, approved, or changed.</p>`;
  $('#close-detail').addEventListener('click', () => { const previous = selectedId; selectedId = null; renderAgents(); $(`[data-agent="${previous}"]`)?.focus(); });
  $('#review-example')?.addEventListener('click', () => {
    agent.state = 'working'; agent.age = 'Just now';
    agent.detail = 'Reviewed in this demo. The example session is now working, and the needs-you count has dropped. In Swarmbell, you make the actual decision in the original harness.';
    renderAgents(); announce('Example reviewed. The needs-you count is now zero. No real agent was changed.');
    $(`[data-agent="${agent.id}"]`)?.focus();
  });
}
function showDetail(id) { selectedId = selectedId === id && !dialog.open ? null : id; renderAgents(); }
$$('.status-filter').forEach((button) => button.addEventListener('click', () => {
  stateFilter = button.dataset.filter;
  $$('.status-filter').forEach((item) => { item.classList.toggle('selected', item === button); item.setAttribute('aria-pressed', String(item === button)); });
  renderAgents();
}));
$('#harness-filter').addEventListener('change', (event) => { harnessFilter = event.target.value; renderAgents(); });
function setView(view, focusTab = false) {
  currentView = view;
  for (const name of ['agents', 'stats']) {
    const active = name === view; const tab = $(`#${name}-tab`);
    tab.classList.toggle('selected', active); tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1;
    $(`#${name}-view`).hidden = !active;
    if (active && focusTab) tab.focus();
  }
  if (view === 'stats') renderStats();
}
$('#agents-tab').addEventListener('click', () => setView('agents'));
$('#stats-tab').addEventListener('click', () => setView('stats'));
$$('.view-tab').forEach((tab) => tab.addEventListener('keydown', (event) => {
  if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) { event.preventDefault(); setView(event.key === 'Home' ? 'agents' : event.key === 'End' ? 'stats' : currentView === 'agents' ? 'stats' : 'agents', true); }
}));
$('#menu-counter').addEventListener('click', () => { setView('agents'); $('#agents-tab').focus(); announce('Example agent list opened.'); });
const statsData = {
  codex: { hours: [1.6, 2.8, 2.1, 3.2, 2.4, .5, .3], waiting: .52 },
  claude: { hours: [.7, 1.3, 1.0, 1.4, 1.1, .2, .1], waiting: .64 },
  cursor: { hours: [.3, .7, .5, .8, .6, .1, 0], waiting: .16 },
};
const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const hourWeights = [2, 5, 8, 11, 9, 5, 8, 12, 13, 10, 7, 6, 4];
function renderStats() {
  const period = Number($('#period-filter').value); const harness = $('#stats-harness').value;
  const source = harness === 'all' ? Object.values(statsData) : [statsData[harness]];
  const multiplier = period / 7;
  const days = dayNames.map((_, i) => source.reduce((total, item) => total + item.hours[i], 0) * multiplier);
  const total = days.reduce((sum, hours) => sum + hours, 0);
  const waiting = source.reduce((sum, item) => sum + item.waiting, 0) * multiplier;
  $('#stat-working').textContent = `${total.toFixed(1)}h`;
  $('#stat-waiting').textContent = `${waiting.toFixed(1)}h`;
  $('#stat-observed').textContent = `${period * 5}h`;
  const max = Math.max(...days, 1);
  $('#weekday-chart').innerHTML = days.map((hours, i) => `<div class="day-bar" aria-label="${dayNames[i]}: ${hours.toFixed(1)} working agent hours"><strong>${hours.toFixed(1)}h</strong><div class="day-bar-fill" style="height:${hours / max * 85}px"></div><span>${dayNames[i]}</span></div>`).join('');
  $('#hour-chart').innerHTML = hourWeights.map((weight, i) => `<span class="hour-fill" title="${i + 8}:00 — ${weight}% of example working time" style="height:${weight / 14 * 60}px" aria-label="${i + 8}:00: ${weight}% of example working time"></span>`).join('');
}
$('#period-filter').addEventListener('change', renderStats);
$('#stats-harness').addEventListener('change', renderStats);
function switcherMatches() {
  const query = $('#switcher-search').value.toLocaleLowerCase().trim();
  return agents.filter((agent) => `${agent.title} ${agent.project} ${harnessNames[agent.harness]}`.toLocaleLowerCase().includes(query)).sort((a, b) => (a.state === 'needs' ? -1 : 1) - (b.state === 'needs' ? -1 : 1));
}
function renderSwitcher() {
  const matches = switcherMatches(); switcherIndex = Math.min(Math.max(0, switcherIndex), Math.max(0, matches.length - 1));
  $('#switcher-results').innerHTML = matches.length ? matches.map((agent, index) => `<button type="button" role="option" id="switcher-option-${agent.id}" class="switcher-result" data-switcher-agent="${agent.id}" aria-selected="${index === switcherIndex}" tabindex="-1">${harnessIcon(agent.harness)}<span><strong>${escapeHTML(agent.title)}</strong><small>${harnessNames[agent.harness]} · ${escapeHTML(agent.project)}</small></span><span class="result-state">${agent.state === 'needs' ? 'Needs you' : agent.state === 'working' ? 'Working' : 'Finished'}</span></button>`).join('') : '<p class="empty-agents">No matching example agents. Try “Atlas” or “Codex”.</p>';
  $('#switcher-search').setAttribute('aria-activedescendant', matches.length ? `switcher-option-${matches[switcherIndex].id}` : '');
  $$('[data-switcher-agent]').forEach((button) => button.addEventListener('click', () => chooseSwitcherAgent(button.dataset.switcherAgent)));
}
function chooseSwitcherAgent(id) {
  dialog.close(); stateFilter = 'all'; harnessFilter = 'all'; $('#harness-filter').value = 'all';
  $$('.status-filter').forEach((button) => { const selected = button.dataset.filter === 'all'; button.classList.toggle('selected', selected); button.setAttribute('aria-pressed', String(selected)); });
  setView('agents'); selectedId = id; renderAgents();
  document.querySelector('#demo').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth', block: 'start' });
  $(`[data-agent="${id}"]`)?.focus({ preventScroll: true });
}
function openSwitcher() { $('#switcher-search').value = ''; switcherIndex = 0; renderSwitcher(); dialog.showModal(); $('#switcher-search').setAttribute('aria-expanded', 'true'); $('#switcher-search').focus(); }
$('#switcher-search').setAttribute('role', 'combobox'); $('#switcher-search').setAttribute('aria-controls', 'switcher-results'); $('#switcher-search').setAttribute('aria-autocomplete', 'list');
$('#open-switcher').addEventListener('click', openSwitcher);
$('.close-switcher').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => $('#switcher-search').setAttribute('aria-expanded', 'false'));
dialog.addEventListener('click', (event) => { if (event.target === dialog) { const rect = dialog.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close(); } });
$('#switcher-search').addEventListener('input', () => { switcherIndex = 0; renderSwitcher(); });
$('#switcher-search').addEventListener('keydown', (event) => {
  const matches = switcherMatches();
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); switcherIndex = (switcherIndex + (event.key === 'ArrowDown' ? 1 : -1) + matches.length) % Math.max(matches.length, 1); renderSwitcher(); }
  if (event.key === 'Enter' && matches.length) { event.preventDefault(); chooseSwitcherAgent(matches[switcherIndex].id); }
});
document.addEventListener('keydown', (event) => { if (event.ctrlKey && event.altKey && event.code === 'Space') { event.preventDefault(); if (!dialog.open) openSwitcher(); } });
$('#reset-demo').addEventListener('click', () => { agents = structuredClone(initialAgents); selectedId = null; stateFilter = 'all'; harnessFilter = 'all'; $('#harness-filter').value = 'all'; $('#period-filter').value = '7'; $('#stats-harness').value = 'all'; $$('.status-filter').forEach((button) => { const selected = button.dataset.filter === 'all'; button.classList.toggle('selected', selected); button.setAttribute('aria-pressed', String(selected)); }); setView('agents'); renderAgents(); renderStats(); announce('Demo reset. Four active agents; one needs you.'); });
renderAgents(); renderStats();
