import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { WebSocketServer } from 'ws';

const fixture = JSON.parse(await readFile(new URL('./snapshot.json', import.meta.url), 'utf8'));
const root = resolve('dist');
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  const file = resolve(root, '.' + (path === '/' ? '/index.html' : path));
  if (!file.startsWith(root + '/')) { response.writeHead(403).end(); return; }
  try {
    const content = await readFile(file);
    response.setHeader('Content-Type', { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css' }[extname(file)] ?? 'application/octet-stream');
    response.end(content);
  } catch { response.writeHead(404).end(); }
});
const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', socket => {
  const state = structuredClone(fixture);
  const send = message => socket.send(JSON.stringify(message));
  send(state);
  socket.on('message', data => {
    const message = JSON.parse(data.toString());
    if (message.type === 'Ping') send({ type: 'Pong', nonce: message.nonce, client_ts_ms: message.client_ts_ms, server_ts_ms: Date.now() });
    if (message.type === 'GetState') send(state);
    if (message.type === 'Command') {
      const command = message.command;
      send({ type: 'CommandResult', request_id: message.request_id, error: null });
      if (command.kind === 'SetRoomOff' || command.kind === 'RecallScene') {
        const room = state.rooms.find(room => room.name === command.room);
        room.target_value = command.kind === 'SetRoomOff' ? { kind: 'off' } : { kind: 'on', scene_id: command.scene_id, cycle_idx: 0 };
        room.target = { phase: 'commanded', owner: 'webui', since_ago_ms: 0 };
        send({ type: 'Entity', kind: 'Room', data: room });
        setTimeout(() => {
          room.actual_value = command.kind === 'SetRoomOff' ? 'off' : 'on'; room.physically_on = room.actual_value === 'on';
          room.target.phase = 'confirmed';
          send({ type: 'Entity', kind: 'Room', data: room });
        }, 100);
      } else if (command.kind === 'SetPlugPower') {
        const plug = state.plugs.find(plug => plug.device === command.device);
        plug.target_value = command.on ? 'on' : 'off'; plug.actual_value.on = command.on;
        send({ type: 'Entity', kind: 'Plug', data: plug });
      }
    }
    if (message.type === 'GetValveHistory') {
      const end = Date.now();
      const points = Array.from({ length: 1440 }, (_, index) => ({
        timestamp_epoch_ms: end - (1440 - index) * 60_000, observed_at_epoch_ms: end - (1440 - index) * 60_000 - 500,
        local_temperature: index > 200 && index < 250 ? null : 20 + Math.sin(index / 90),
        reported_setpoint: index < 700 ? 18 : 21, target: { kind: 'setpoint', temperature: index < 700 ? 18 : 21 },
        heating_demand: Math.round(40 + 35 * Math.sin(index / 90)), battery: 80, freshness: 'fresh',
      }));
      send({ type: 'ValveHistory', request_id: message.request_id, device: message.device, from_epoch_ms: end - 86400_000, to_epoch_ms: end, points, error: null });
    }
  });
});
server.listen(18780, '127.0.0.1');
