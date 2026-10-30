// Renders the product mockups and the few interactions on the page. The mockups copy the
// app's own views (DayView, DayTimeline, AgentLane, MenuBarView) in macOS dark appearance,
// with made-up data, so both language versions share one source. The app itself is in
// English, so the mockups are too.
(() => {
  'use strict';

  const color = {
    code: '#4F7CFF', writing: '#2BB8A4', research: '#5FB760', messaging: '#7E57C2',
    video: '#0097A7', social: '#FF5252', claude: '#D97757', codex: '#10A37F',
    // System colors, dark appearance, as used by GoalBar and ScoreRing.
    focus: '#0A84FF', meetings: '#40C8E0', other: '#98989D', waiting: '#BF5AF2',
    distracted: '#FF453A', green: '#30D158', indigo: '#5E5CE6',
  };

  const icons = {
    focus: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/>',
    meeting: '<circle cx="9" cy="8" r="3.2"/><path d="M3 19.5c0-3.3 2.7-5.6 6-5.6s6 2.3 6 5.6"/><circle cx="17" cy="9" r="2.5"/><path d="M16.2 13.7c2.8.2 4.8 2.1 4.8 5"/>',
    break: '<path d="M4 9h12v4.5a5.5 5.5 0 0 1-5.5 5.5h-1A5.5 5.5 0 0 1 4 13.5V9Z"/><path d="M16 10.5h1.5a2.5 2.5 0 0 1 0 5H16"/><path d="M8 3.5v2.5M12 3.5v2.5"/>',
    gear: '<circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.6M12 18.6v2.6M5.5 5.5l1.8 1.8M16.7 16.7l1.8 1.8M2.8 12h2.6M18.6 12h2.6M5.5 18.5l1.8-1.8M16.7 7.3l1.8-1.8"/>',
    power: '<path d="M12 3v8"/><path d="M6.4 6.6a8 8 0 1 0 11.2 0"/>',
    sparkle: '<path fill="currentColor" stroke="none" d="M12 2.5c.5 5 4.5 9 9.5 9.5-5 .5-9 4.5-9.5 9.5-.5-5-4.5-9-9.5-9.5 5-.5 9-4.5 9.5-9.5Z"/>',
    code: '<path d="M8.5 7 3.5 12l5 5M15.5 7l5 5-5 5"/>',
    folder: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h3.7l2 2h7.3A2.5 2.5 0 0 1 21 9.5v7a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16.5v-9Z"/>',
    bubble: '<path d="M4.5 5h15A1.5 1.5 0 0 1 21 6.5v8a1.5 1.5 0 0 1-1.5 1.5H10l-5 4v-4h-.5A1.5 1.5 0 0 1 3 14.5v-8A1.5 1.5 0 0 1 4.5 5Z"/>',
    hand: '<path d="M8 12.5V6a1.5 1.5 0 0 1 3 0v5m0-6.5a1.5 1.5 0 0 1 3 0V11m0-5a1.5 1.5 0 0 1 3 0v8a7 7 0 0 1-7 7h-.3A6.7 6.7 0 0 1 5 14.3V11a1.5 1.5 0 0 1 3 0v1.5"/>',
    desktop: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8.5 20h7M12 16v4"/>',
    today: '<rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
    reports: '<path d="M5 20V11M10 20V5M15 20v-6M20 20V8"/>',
    review: '<path d="M4 6h11M4 12h11M4 18h6"/><path d="m14.5 17 2.2 2.2L21 15"/>',
    categories: '<circle cx="7.5" cy="7.5" r="3"/><circle cx="16.5" cy="7.5" r="3"/><circle cx="7.5" cy="16.5" r="3"/><circle cx="16.5" cy="16.5" r="3"/>',
    rules: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
    timer: '<circle cx="12" cy="13.5" r="7.5"/><path d="M12 10v3.5l2.5 2M9.5 2.5h5"/>',
    switch: '<path d="M4 8h15l-3.5-3.5M20 16H5l3.5 3.5"/>',
    left: '<path d="m14.5 6-6 6 6 6"/>',
    right: '<path d="m9.5 6 6 6-6 6"/>',
    wifi: '<path d="M2.5 9a14 14 0 0 1 19 0M5.5 12.5a9.5 9.5 0 0 1 13 0M8.6 15.9a5 5 0 0 1 6.8 0"/><circle cx="12" cy="19" r="1.2" fill="currentColor"/>',
    up: '<path d="m6 15 6-6 6 6"/>',
  };

  const icon = (name, cls = '') =>
    `<svg class="m-icon ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;

  /** Minutes since midnight → "13:05". */
  const clock = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(Math.round(m % 60)).padStart(2, '0')}`;

  /** Minutes → "2h 15m", like Format.duration. */
  const duration = (m) => {
    const hours = Math.floor(m / 60), minutes = Math.round(m % 60);
    if (!hours) return `${minutes}m`;
    return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
  };

  // MARK: Shared pieces

  function ring(value, size, caption, tint) {
    const stroke = size * 0.11, r = (size - stroke) / 2, length = 2 * Math.PI * r;
    return `<div class="m-ring" style="--size:${size}px">
      <svg viewBox="0 0 ${size} ${size}" width="${size}" height="${size}">
        <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="rgba(255,255,255,.1)" stroke-width="${stroke}"/>
        <circle class="m-ring-value" cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${tint}" stroke-width="${stroke}"
          stroke-linecap="round" stroke-dasharray="${length}" stroke-dashoffset="${length * (1 - value / 100)}"
          style="--length:${length}" transform="rotate(-90 ${size / 2} ${size / 2})"/>
      </svg>
      <b>${value}</b>
      <span>${caption}</span>
    </div>`;
  }

  // Today's split, in minutes: 6h 24m tracked of an 8h target.
  const day = {
    target: 480,
    parts: [
      { name: 'Focus', minutes: 250, color: color.focus },
      { name: 'Meetings', minutes: 45, color: color.meetings },
      { name: 'Other', minutes: 52, color: color.other },
      { name: 'Waiting on agents', minutes: 24, color: color.waiting },
      { name: 'Distracted', minutes: 13, color: color.distracted },
    ],
  };
  const tracked = day.parts.reduce((sum, part) => sum + part.minutes, 0);

  function goalBar(highlight) {
    const parts = day.parts.map((part) =>
      `<i class="${highlight && part.name !== highlight ? 'dim' : ''}" style="width:${(part.minutes / day.target) * 100}%;--c:${part.color}"></i>`).join('');
    return `<div class="m-goal">${parts}</div>`;
  }

  function legend(names, withTitles = true) {
    return day.parts.filter((part) => names.includes(part.name)).map((part) =>
      `<span class="m-legend-item"><i style="background:${part.color}"></i>${withTitles ? `<em>${part.name}</em>` : ''}${duration(part.minutes)}</span>`).join('');
  }

  // MARK: Day timeline (DayTimeline + AgentBlockView)

  /**
   * Lays out streams and agent blocks like DayTimeline: columns side by side, each item
   * spanning the columns to its right that stay free while it lasts (placed by hand here).
   */
  function timeline(spec) {
    const { from, to, pph, columns, width, items, sessions = [], now, notes = [] } = spec;
    const y = (m) => ((m - from) / 60) * pph;
    const timeColumn = 44, spacing = 12, gutter = 6, sessionColumn = sessions.length ? 104 : 0;
    const left = timeColumn + spacing;
    const streamsWidth = width - left - (sessionColumn ? sessionColumn + spacing : 0);
    const column = (streamsWidth - (columns - 1) * gutter) / columns;
    const height = y(to);

    let html = '';
    for (let m = Math.ceil(from / 60) * 60; m <= to; m += 60) {
      html += `<div class="m-hour" style="top:${y(m)}px"><span>${clock(m)}</span><i></i></div>`;
    }
    for (const item of items) {
      const top = y(item.start);
      const h = Math.max(30, y(item.end) - top - 3);
      const x = left + item.col * (column + gutter);
      const w = column * item.span + gutter * (item.span - 1);
      const tint = item.agent ? color[item.agent] : item.color;
      const body = item.agent ? agentBody(item, h) : streamBody(item, h);
      const bar = item.agent ? agentBar(item, pph) : '';
      html += `<div class="m-item ${item.agent ? 'agent' : 'stream'} ${item.live ? 'live' : ''}" data-note="${item.note || ''}"
        style="top:${top}px;left:${x}px;width:${w}px;height:${h}px;--c:${tint}">${bar}<div class="m-item-body">${body}</div></div>`;
    }
    for (const note of notes) {
      const top = y(note.start), h = y(note.end) - top - 3;
      const x = left + note.col * (column + gutter);
      html += `<div class="m-away" data-note="${note.marker || ''}" style="top:${top}px;left:${x}px;width:${column}px;height:${h}px">
        <span>${note.text}</span></div>`;
    }
    for (const session of sessions) {
      const top = y(session.start), h = Math.max(4, y(session.end) - top - 2);
      html += `<div class="m-session" style="top:${top}px;left:${width - sessionColumn}px;width:${sessionColumn}px;height:${h}px;--c:${session.color}">
        <b>${icon(session.icon)}${session.kind}</b><span>${clock(session.start)} – ${clock(session.end)}</span></div>`;
    }
    if (now) html += `<div class="m-now" style="top:${y(now) - 4}px;left:${left - 4}px"></div>`;
    return `<div class="m-timeline" style="height:${height}px;width:${width}px">${html}</div>`;
  }

  function timeLabel(item) {
    const end = item.live ? 'now' : clock(item.end);
    return `${clock(item.start)}–${end}`;
  }

  function streamBody(item, h) {
    if (h < 44) {
      return `<div class="m-line"><b>${item.category}</b><span class="m-desc">${item.title}</span><span class="m-time">${timeLabel(item)}</span></div>`;
    }
    const rows = Math.max(0, Math.floor((h - (h >= 80 ? 74 : 56)) / 18));
    const apps = (item.apps || []).slice(0, rows).map(([name, time]) =>
      `<div class="m-row"><span>${name}</span><span>${time}</span></div>`).join('');
    return `<div class="m-cap"><b>${item.category}</b><span class="m-time">${timeLabel(item)}</span></div>
      <div class="m-title ${h >= 80 ? 'two' : ''}">${item.title}</div>${apps ? `<div class="m-rows">${apps}</div>` : ''}`;
  }

  const agentName = { claude: 'Claude Code', codex: 'Codex' };
  const agentIcon = { claude: 'sparkle', codex: 'code' };

  function agentBody(item, h) {
    const working = item.pieces.reduce((sum, [start, end]) => sum + (end - start), 0);
    const label = `${timeLabel(item)} · ${duration(working)}`;
    if (h < 44) {
      return `<div class="m-line">${icon(agentIcon[item.agent], 'tint')}<span class="m-desc strong">${item.title}</span><span class="m-time">${label}</span></div>`;
    }
    const rows = Math.max(0, Math.floor((h - (h >= 80 ? 74 : 56)) / 18));
    const details = (item.details || []).slice(0, rows).map(([symbol, text]) =>
      `<div class="m-row">${icon(symbol)}<span>${text}</span></div>`).join('');
    return `<div class="m-cap"><b>${icon(agentIcon[item.agent])}${agentName[item.agent]}</b><span class="m-time">${label}</span></div>
      <div class="m-title ${h >= 80 ? 'two' : ''}">${item.title}</div>${details ? `<div class="m-rows details">${details}</div>` : ''}`;
  }

  /** Solid where the agent worked, faint where it waited for its next prompt. */
  function agentBar(item, pph) {
    const pieces = item.pieces.map(([start, end]) =>
      `<i style="top:${((start - item.start) / 60) * pph}px;height:${Math.max(2, ((end - start) / 60) * pph)}px"></i>`).join('');
    return `<div class="m-agent-bar">${pieces}</div>`;
  }

  // MARK: Main window (MainView + DayView)

  function sidebar() {
    const pages = [['today', 'Today'], ['reports', 'Reports'], ['review', 'Review'], ['categories', 'Categories'], ['rules', 'Rules']];
    return `<aside class="m-sidebar">
      <div class="m-traffic"><i></i><i></i><i></i></div>
      ${pages.map(([symbol, title], index) =>
        `<div class="m-side-item ${index === 0 ? 'on' : ''}">${icon(symbol)}<span>${title}</span>${title === 'Review' ? '<em>3</em>' : ''}</div>`).join('')}
    </aside>`;
  }

  function overview() {
    const fact = (symbol, title, value, detail) =>
      `<div class="m-fact">${icon(symbol)}<div><span>${title}</span><b>${value}</b><small>${detail}</small></div></div>`;
    return `<section class="m-overview">
      ${ring(84, 100, 'High', color.green)}
      <div class="m-ov-main">
        <div class="m-tracked"><b>${duration(tracked)}</b><span>tracked of ${duration(day.target)}</span></div>
        ${goalBar()}
        <div class="m-legend">${legend(['Focus', 'Meetings', 'Other', 'Waiting on agents', 'Distracted'])}</div>
      </div>
      <div class="m-ov-divider"></div>
      <div class="m-facts">
        ${fact('focus', 'Deep work', '3h 5m', 'in stretches of 25 min or more')}
        ${fact('timer', 'Longest focus', '1h 42m', 'without a real break')}
        ${fact('switch', 'Switching', 'Steady', '9 switches per hour')}
        ${fact('sparkle', 'Agents', '2h 50m', '3 sessions, up to 2 at once')}
      </div>
    </section>`;
  }

  // Wednesday afternoon, 13:00–16:00, with "now" at 15:52.
  const afternoon = {
    from: 780, to: 960, pph: 116, columns: 3, now: 952,
    items: [
      { category: 'Code', color: color.code, start: 785, end: 920, col: 0, span: 1,
        title: 'Refactored the session engine and fixed the break-reminder tests',
        apps: [['Xcode', '1h 24m'], ['Terminal', '26m'], ['developer.apple.com', '12m'], ['github.com', '9m'], ['Simulator', '6m']] },
      { agent: 'claude', start: 800, end: 875, col: 1, span: 1, title: 'Add OpenAI-compatible model providers',
        pieces: [[800, 822], [828, 851], [856, 875]],
        details: [['folder', '~/dev/weft'], ['bubble', '4 prompts'], ['hand', 'Waited 6m for you']] },
      { category: 'Messaging', color: color.messaging, start: 826, end: 852, col: 2, span: 1,
        title: 'Answered review comments on the timeline PR' },
      { category: 'Research', color: color.research, start: 855, end: 888, col: 2, span: 1,
        title: 'Read up on FSEvents latency and coalescing', apps: [['developer.apple.com', '21m']] },
      { category: 'Video Conferencing', color: color.video, start: 900, end: 930, col: 1, span: 2,
        title: 'Weekly sync with the design team', apps: [['Zoom', '30m']] },
      { category: 'Writing', color: color.writing, start: 935, end: 952, col: 0, span: 1, live: true,
        title: 'Release notes for 0.2' },
      { agent: 'codex', start: 932, end: 952, col: 1, span: 2, live: true, title: 'Fix column layout for overlapping streams',
        pieces: [[932, 952]] },
    ],
    sessions: [
      { kind: 'Focus', icon: 'focus', color: '#7D9BFF', start: 785, end: 835 },
      { kind: 'Meeting', icon: 'meeting', color: '#5ED0DF', start: 900, end: 930 },
    ],
  };

  function mainWindow(width, height) {
    const contentWidth = width - 216 - 44;
    return `<div class="m-window" style="width:${width}px;height:${height}px">
      ${sidebar()}
      <div class="m-main">
        <header class="m-toolbar">
          <b>Today</b><span>Wednesday, 28 October</span>
          <div class="m-nav">${icon('left')}${icon('right')}</div>
        </header>
        ${overview()}
        <div class="m-tabs"><span class="on">Timeline</span><span>Categories &amp; Apps</span><span>Log</span></div>
        <div class="m-scroll">${timeline({ ...afternoon, width: contentWidth })}</div>
      </div>
    </div>`;
  }

  // MARK: Menu bar (MenuBarView)

  function popover() {
    const tile = (symbol, title, minutes) =>
      `<div class="m-tile">${icon(symbol)}<b>${title}</b><span>${minutes}</span></div>`;
    return `<div class="m-pop">
      <div class="m-pop-today">
        <div><span class="m-caption">Wednesday</span><b class="m-pop-big">${duration(tracked)}</b>
          <span class="m-caption">of ${duration(day.target)} · ${Math.round((tracked / day.target) * 100)}%</span></div>
        ${ring(84, 56, 'High', color.green)}
      </div>
      ${goalBar()}
      <div class="m-legend compact">${legend(['Focus', 'Meetings', 'Waiting on agents', 'Distracted'], false)}</div>
      <div class="m-current">
        <div class="m-app-icon"></div>
        <div class="m-current-text"><b>Pages</b><span>Weft 0.2 release notes</span></div>
        <span class="m-capsule" style="--c:${color.writing}">Writing</span>
      </div>
      <div class="m-tiles">${tile('focus', 'Focus', '50m')}${tile('meeting', 'Meeting', '30m')}${tile('break', 'Break', '5m')}</div>
      <hr>
      <footer class="m-pop-foot">
        <span class="m-tracking"><i></i>Tracking</span>
        <span class="m-spacer"></span>
        <span>Open Dashboard</span>${icon('gear')}${icon('power')}
      </footer>
    </div>`;
  }

  function menuBar(compact) {
    const menus = compact ? '' : ['File', 'Edit', 'Format', 'Arrange', 'View', 'Window', 'Help'].map((m) => `<span>${m}</span>`).join('');
    return `<div class="m-menubar">
      <div class="m-menus"><b>Pages</b>${menus}</div>
      <div class="m-status">
        <span class="m-weft-glyph">${icon('focus')}</span>
        ${icon('wifi')}
        <span class="m-battery"><i></i></span>
        <span>${compact ? '15:52' : 'Wed 28 Oct  15:52'}</span>
      </div>
    </div>`;
  }

  // MARK: Compositions

  const builders = {
    hero(stage) {
      if (stage.clientWidth < 640) {
        return { width: 380, height: 452, html: `${menuBar(true)}<div class="m-place" style="left:20px;top:40px">${popover()}</div>` };
      }
      return {
        width: 1280, height: 800,
        html: `${menuBar(false)}
          <div class="m-place" style="left:0;top:64px">${mainWindow(960, 728)}</div>
          <div class="m-place m-pop-place" style="left:912px;top:38px">${popover()}</div>`,
      };
    },

    popover() {
      return { width: 372, height: 412, html: `<div class="m-place" style="left:16px;top:8px">${popover()}</div>` };
    },

    agents() {
      const width = 680;
      const spec = {
        from: 780, to: 915, pph: 150, columns: 3, width,
        items: [
          { category: 'Code', color: color.code, start: 780, end: 828, col: 0, span: 1,
            title: 'Reviewed the model settings and wrote tests', apps: [['Xcode', '31m'], ['Terminal', '12m']] },
          { agent: 'claude', start: 785, end: 880, col: 1, span: 1, title: 'Add OpenAI-compatible model providers', note: '1',
            pieces: [[785, 808], [812, 846], [852, 880]],
            details: [['folder', '~/dev/weft'], ['bubble', '5 prompts'], ['hand', 'Waited 6m for you']] },
          { agent: 'codex', start: 820, end: 905, col: 2, span: 1, title: 'Cut permission waits out of HAPI turns', note: '3',
            pieces: [[820, 851], [858, 905]],
            details: [['desktop', 'mac-mini'], ['folder', '~/src/hapi'], ['bubble', '3 prompts']] },
          { category: 'Messaging', color: color.messaging, start: 852, end: 872, col: 0, span: 1,
            title: 'Replied to the HAPI release thread' },
          { category: 'Code', color: color.code, start: 875, end: 915, col: 0, span: 1,
            title: 'Merged both branches and ran the suite', apps: [['Xcode', '24m']] },
        ],
        notes: [{ start: 828, end: 852, col: 0, marker: '2', text: 'Away · 24m<br>counted as waiting' }],
      };
      return {
        width, height: 58 + (spec.to - spec.from) / 60 * spec.pph + 8,
        html: `<div class="m-agents">
          <div class="m-agents-head">
            <div class="m-fact">${icon('sparkle')}<div><span>Agents</span><b>2h 50m</b><small>3 sessions, up to 2 at once</small></div></div>
            <div class="m-agents-goal">${goalBar('Waiting on agents')}<div class="m-legend">${legend(['Waiting on agents'])}</div></div>
          </div>
          ${timeline(spec)}
        </div>`,
      };
    },
  };

  // MARK: Agent session detail (AgentBlockDetail)

  function agentDetail() {
    const meanwhile = [['Code', color.code, '48m'], ['Messaging', color.messaging, '20m']];
    return `<div class="m-pop m-detail">
      <div class="m-detail-head">
        <b>Add OpenAI-compatible model providers</b>
        <div class="m-detail-who"><span style="color:${color.claude}">${icon('sparkle')}Claude Code</span><i>·</i><span>This Mac</span></div>
        <small>~/dev/weft</small>
      </div>
      <hr>
      <div class="m-detail-time"><span>13:05 – 14:40</span><span class="m-muted">Worked 1h 25m over 5 prompts, waited 6m for your answers</span></div>
      <hr>
      <div class="m-detail-meanwhile">
        <span class="m-caption">Meanwhile you</span>
        ${meanwhile.map(([name, tint, time]) => `<div class="m-row"><span><i style="background:${tint}"></i>${name}</span><span>${time}</span></div>`).join('')}
        <div class="m-row"><span><i class="ring"></i>Away from the Mac</span><span>24m</span></div>
      </div>
    </div>`;
  }

  builders.agentDetail = () => ({ width: 352, height: 300, html: `<div class="m-place" style="left:6px;top:6px">${agentDetail()}</div>` });

  /** Draws a mockup at its design size and scales it to fit the stage. */
  function mount(stage) {
    const build = builders[stage.dataset.mock];
    let layout = '';
    const render = () => {
      const { width, height, html } = build(stage);
      const key = `${width}x${height}`;
      if (key !== layout) {
        layout = key;
        stage.innerHTML = `<div class="m-canvas" style="width:${width}px;height:${height}px">${html}</div>`;
      }
      const canvas = stage.firstElementChild;
      const scale = Math.min(1, stage.clientWidth / width);
      canvas.style.transform = `translateX(${(stage.clientWidth - width * scale) / 2}px) scale(${scale})`;
      stage.style.height = `${height * scale}px`;
    };
    render();
    let lastWidth = stage.clientWidth;
    new ResizeObserver(() => {
      if (stage.clientWidth !== lastWidth) { lastWidth = stage.clientWidth; render(); }
    }).observe(stage);
  }

  // MARK: Weave (switches → threads)

  /** A small seeded generator, so the barcode is the same on every visit. */
  function random(seed) {
    return () => {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function weave(root) {
    const from = 540, to = 720;
    const threads = [
      { name: 'Code', start: 545, end: 680, color: color.code, title: 'Refactored the session engine' },
      { name: 'Messaging', start: 588, end: 612, color: color.messaging },
      { name: 'Research', start: 615, end: 648, color: color.research },
      { name: 'Meetings', start: 660, end: 690, color: color.video },
      { name: 'Writing', start: 694, end: 720, color: color.writing },
    ];
    const x = (m) => ((m - from) / (to - from)) * 100;

    // What the Mac saw: hopping between the apps behind whatever was open (Xcode, Terminal,
    // the docs), with message pings and the odd detour in between.
    const shades = {
      Code: ['#4F7CFF', '#7397FF', '#3559D1'], Messaging: ['#7E57C2', '#9A78DB'], Research: ['#5FB760', '#4A9A4C'],
      Meetings: ['#0097A7'], Writing: ['#2BB8A4', '#5ED0BF'],
    };
    const next = random(11);
    const switches = [];
    for (let t = from + 4; t < to;) {
      const open = threads.filter((thread) => t >= thread.start && t < thread.end);
      let pick = open[Math.floor(next() * open.length)];
      if (!pick) { t += 1.5; continue; }
      let tint = shades[pick.name][Math.floor(next() * shades[pick.name].length)];
      let length = 0.4 + next() * (pick.name === 'Meetings' ? 12 : pick.name === 'Code' ? 3.6 : 2.2);
      const detour = next();
      if (pick.name !== 'Meetings' && detour < 0.12) { tint = shades.Messaging[0]; length = 0.3 + next() * 0.8; }
      else if (pick.name !== 'Meetings' && detour < 0.17) { tint = color.social; length = 0.4 + next() * 1.2; }
      switches.push({ start: t, end: Math.min(to, t + length), color: tint });
      t += length;
    }

    root.querySelector('[data-barcode]').innerHTML = switches.map((s) =>
      `<i style="left:${x(s.start)}%;width:${x(s.end) - x(s.start)}%;--c:${s.color}"></i>`).join('');
    root.querySelector('[data-switches]').textContent = switches.length;
    root.querySelector('[data-threads]').innerHTML = threads.map((thread, index) => `
      <div class="weave-lane">
        <span class="weave-name" style="color:${thread.color}">${thread.name}</span>
        <div class="weave-track"><div class="thread ${thread.title ? '' : 'short'}" style="left:${x(thread.start)}%;width:${x(thread.end) - x(thread.start)}%;--c:${thread.color};--i:${index}">
          <span>${thread.title ? `${thread.title} · ` : ''}${duration(thread.end - thread.start)}</span></div></div>
      </div>`).join('');
  }

  // MARK: Hero threads

  function heroThreads(svg) {
    const colors = ['#4F7CFF', '#2BB8A4', '#C356F0', '#E2B93B', '#F44336'];
    const paths = colors.map((tint, index) => {
      const base = 140 + index * 34, amplitude = 46 + index * 6, phase = index * 0.9;
      let d = '';
      for (let step = 0; step <= 64; step++) {
        const px = step * 25;
        const py = base + Math.sin(step / 7 + phase) * amplitude + Math.sin(step / 3.1 + phase * 2) * 8;
        d += `${step ? 'L' : 'M'}${px} ${py.toFixed(1)}`;
      }
      return `<path d="${d}" stroke="${tint}" style="--i:${index}"/>`;
    }).join('');
    svg.innerHTML = `<g class="glow">${paths}</g><g class="line">${paths}</g>`;
  }

  // MARK: Page

  document.querySelectorAll('[data-mock]').forEach(mount);
  document.querySelectorAll('[data-weave]').forEach(weave);
  document.querySelectorAll('[data-hero-threads]').forEach(heroThreads);

  // Fade sections in as they scroll into view.
  const reveal = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) { entry.target.classList.add('in'); reveal.unobserve(entry.target); }
    }
  }, { rootMargin: '0px 0px -12% 0px' });
  document.querySelectorAll('.reveal').forEach((el) => reveal.observe(el));

  // Shade the nav once the page scrolls.
  const nav = document.querySelector('.nav');
  const shade = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  shade();
  window.addEventListener('scroll', shade, { passive: true });

  // Copy buttons on code samples.
  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.classList.add('copied');
        setTimeout(() => button.classList.remove('copied'), 1400);
      } catch { /* Clipboard needs a secure context; nothing to do otherwise. */ }
    });
  });
})();
