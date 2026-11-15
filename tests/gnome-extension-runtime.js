imports.gi.versions.Meta = ARGV[0];
imports.gi.versions.St = ARGV[0];
imports.gi.versions.Clutter = ARGV[0];
const nativeGLib = imports.gi.GLib;
const nativeMeta = imports.gi.Meta;
const nativeSt = imports.gi.St;
const nativeClutter = imports.gi.Clutter;

function check(condition, message) {
    if (!condition)
        throw new Error(message);
}

function loadInstalled(path, symbol, dependencies) {
    let source = new TextDecoder().decode(nativeGLib.file_get_contents(path)[1]);
    for (const match of source.matchAll(/^import (\w+) from 'gi:\/\/(\w+)';$/gm)) {
        const namespace = imports.gi[match[2]];
        dependencies[match[1]] = match[2] === 'St' ? actorBoundary(namespace) : namespace;
    }
    source = source.replace(/^import .*;\n/gm, '')
        .replace(/export default class /g, 'class ')
        .replace(/export let /g, 'let ')
        .replace(/^export \{.*\};$/gm, '');
    return new Function(...Object.keys(dependencies), source + '\nreturn ' + symbol + ';')(...Object.values(dependencies));
}

class Actor {
    constructor(properties) {
        Object.assign(this, properties);
        this.children = [];
        this.clutter_text = {};
        this.width = 100;
        this.destroyed = false;
    }
    add_child(child) { this.children.push(child); child.owner = this; }
    insert_child_at_index(child, index) { this.children.splice(index, 0, child); child.owner = this; }
    get_n_children() { return this.children.length; }
    set_y_align(value) { this.y_align = value; }
    set_position(x, y) { Object.assign(this, {x, y}); }
    ease(properties) {
        Object.assign(this, properties);
        if (properties.onComplete)
            properties.onComplete();
    }
    destroy() {
        this.destroyed = true;
        if (this.owner)
            this.owner.children.splice(this.owner.children.indexOf(this), 1);
        for (const child of [...this.children])
            child.destroy();
    }
    [Symbol.iterator]() { return this.children[Symbol.iterator](); }
}

function actorBoundary(namespace) {
    const boundary = Object.create(namespace);
    for (const name of ['Bin', 'BoxLayout', 'Label', 'Icon']) {
        const properties = new Set(namespace[name].list_properties().map(property => property.name));
        boundary[name] = class extends Actor {
            constructor(values) {
                for (const key of Object.keys(values))
                    check(properties.has(key.replaceAll('_', '-')), 'Pinned St.' + name + ' has no property ' + key);
                super(values);
            }
        };
    }
    return boundary;
}

function quietCallback() {
    const responses = [];
    let originalBuilds = 0;
    class InhibitShortcutsDialog {
        constructor() {
            this._dialog = {open() {}, close() {}};
            this._buildLayout();
        }
        _buildLayout() { originalBuilds++; }
        _emitResponse(response) { responses.push(response); }
    }
    const original = InhibitShortcutsDialog.prototype._buildLayout;
    const Quiet = loadInstalled(ARGV[1], 'QuietShortcuts', {ShortcutsDialog: {InhibitShortcutsDialog}});
    const extension = new Quiet();
    extension.enable();
    const dialog = new InhibitShortcutsDialog();
    dialog._dialog.open();
    check(responses.length === 1 && responses[0] === nativeMeta.InhibitShortcutsDialogResponse.ALLOW,
        'Quiet callback must emit exactly the real Meta ALLOW response');
    dialog._dialog.close();
    extension.disable();
    check(InhibitShortcutsDialog.prototype._buildLayout === original, 'Quiet disable must restore the original layout callback');
    new InhibitShortcutsDialog();
    check(originalBuilds === 1, 'Quiet disable must retain the normal dialog lifecycle');
    print('PASS Quiet installed callback: real Meta ALLOW and restored lifecycle');
}

function calendarCallback() {
    const flags = new Map([
        ['style-past-days', true], ['style-ongoing-events', false], ['hide-past-events', false],
    ]);
    let settingsChanged;
    let disconnected = false;
    const settings = {
        get_boolean(name) { check(flags.has(name), 'Unexpected setting ' + name); return flags.get(name); },
        get_int() { return 0; },
        connect(signal, callback) { settingsChanged = callback; return 1; },
        disconnect(id) { check(id === 1, 'Unexpected subscription'); disconnected = true; },
    };
    const event = {summary: 'Review event', date: new Date(0), end: new Date(1)};
    let events = [event];
    let syncs = 0;
    const originalReload = function () {};
    const list = new Actor({});
    const eventsItem = {
        _eventSource: {isLoading: false, getEvents() { return events; }},
        _reloading: false, _eventsList: list, _startDate: new Date(0), _endDate: new Date(),
        _reloadEvents: originalReload, _formatEventTime() { return '12:30'; }, _sync() { syncs++; },
    };
    class Extension { getSettings() { return settings; } }
    const Calendar = loadInstalled(ARGV[2], 'DimCompletedCalendarEventsExtension', {
        Extension, Main: {panel: {statusArea: {dateMenu: {_eventsItem: eventsItem}}}}, _: text => text,
    });
    const extension = new Calendar();
    extension.enable();
    eventsItem._reloadEvents();
    check(!eventsItem._reloading && syncs === 1, 'Calendar must clear the reload guard and synchronize');
    check(list.children.length === 1, 'Calendar must render one event');
    const box = list.children[0];
    check(box.orientation === nativeClutter.Orientation.VERTICAL, 'Calendar event layout must use the real vertical orientation enum');
    check(box.children[0].text === event.summary && box.children[1].text === '12:30', 'Calendar must preserve event summary and time');
    check(box.children[0].style === 'color: #9a9996', 'Calendar must retain completed-event styling');
    eventsItem._reloadEvents();
    check(box.destroyed && !eventsItem._reloading, 'Calendar must replace old event actors and remain reloadable');
    flags.set('hide-past-events', true);
    settingsChanged();
    eventsItem._reloadEvents();
    check(list.children.length === 1 && list.children[0].text === 'No Events' && !eventsItem._reloading,
        'Calendar must preserve hiding completed events and its placeholder');
    flags.set('hide-past-events', false);
    events = [];
    settingsChanged();
    eventsItem._reloadEvents();
    check(list.children[0].text === 'No Events' && !eventsItem._reloading, 'Calendar must remain reloadable with no events');
    extension.disable();
    check(eventsItem._reloadEvents === originalReload && disconnected, 'Calendar disable must restore callback and disconnect settings');
    print('PASS Calendar installed callback: real GI property contract, vertical events, reload guard, settings and lifecycle');
}

function gsconnectCallback() {
    const chrome = [];
    const Main = {layoutManager: {
        addTopChrome(actor) { chrome.push(actor); },
        removeChrome(actor) { chrome.splice(chrome.indexOf(actor), 1); },
    }};
    const Tooltip = loadInstalled(ARGV[3], 'Tooltip', {Main, HAS_CLUTTER_CONTROLLERS: true, HAS_ST_ORIENTATION: true});
    const tooltip = Object.create(Tooltip.prototype);
    Object.assign(tooltip, {
        _text: 'Device', _markup: null, _gicon: new imports.gi.Gio.ThemedIcon({name: 'smartphone-symbolic'}),
        _custom: null, _bin: null, _showing: false, _hoverTimeoutId: 0,
        parent: {width: 100, get_transformed_position() { return [10, 20]; }, disconnect() {}},
    });
    tooltip._show();
    check(tooltip._bin.child.icon.y_align === nativeClutter.ActorAlign.START, 'GSConnect tooltip must use the real Clutter alignment enum');
    check(tooltip._showing && chrome.length === 1 && tooltip.label.text === 'Device', 'GSConnect tooltip must show its text and icon');
    tooltip.destroy();
    check(chrome.length === 0, 'GSConnect tooltip destruction must remove its chrome');
    print('PASS GSConnect installed tooltip callback: real GI enum and controlled actors; not live-symptom attribution');
}

const failures = [];
for (const test of [quietCallback, calendarCallback, gsconnectCallback]) {
    try {
        test();
    } catch (error) {
        printerr(test.name + ': ' + error.name + ': ' + error.message);
        failures.push(test.name);
    }
}
print('SKIP production-native actor and Shell-session checks: no initialized compositor; actor dummies are validated against real GI properties');
check(failures.length === 0, 'Failed API-boundary callbacks: ' + failures.join(', '));
