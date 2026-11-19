const mq = (() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const stateLabels = new Map([
    ['RUNNING', ['消费中', 'good']],
    ['STARTING', ['启动中', 'warn']],
    ['DRAINING', ['排空中', 'warn']],
    ['PAUSED', ['已暂停', 'neutral']],
    ['PARTIAL', ['部分运行', 'warn']],
    ['UNAVAILABLE', ['不可用', 'bad']]
  ]);
  const dialog = byId('confirm');
  const message = byId('mq-notice');
  const results = byId('results');
  const resultList = results.querySelector('ul');
  let snapshot;
  let stale = true;
  let loading = false;
  let operating = false;
  let poll;
  let confirmation;
  let instances = new Map();

  async function request(url, body) {
    const response = await fetch(url, {
      method: body ? 'POST' : 'GET',
      body: body ? JSON.stringify(body) : undefined,
      headers: body ? { 'Content-Type': 'application/json' } : undefined,
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'error',
      signal: AbortSignal.timeout(15000)
    });
    const payload = await response.json().catch(() => null);
    if (!response.ok || Number(payload?.code) !== 200) {
      const status = response.ok ? Number(payload?.code) : response.status;
      throw new Error(payload?.msg || (status ? `请求失败（${status}）` : '响应格式不正确'));
    }
    return payload.data;
  }

  function reset() {
    snapshot = undefined;
    instances.clear();
    stale = true;
    loading = false;
    operating = false;
    clearTimeout(poll);
    confirmation = undefined;
    if (dialog.open) dialog.close();
    results.hidden = true;
    resultList.replaceChildren();
    message.textContent = '';
  }

  function rowState(row) {
    return row.error || !stateLabels.has(row.status?.state)
      ? 'UNAVAILABLE' : row.status.state;
  }

  function allowedActions(row) {
    if (!row?.instanceId) return [];
    switch (rowState(row)) {
      case 'RUNNING': return ['PAUSE'];
      case 'PAUSED': return ['RESUME'];
      case 'PARTIAL': return ['PAUSE', 'RESUME'];
      default: return [];
    }
  }

  function displayAddress(row) {
    return `${row.ip?.includes(':') ? `[${row.ip}]` : (row.ip || '—')}:${row.port ?? '—'}`;
  }

  function displayTarget(row) {
    return `${row.service} · ${displayAddress(row)} · 版本 ${row.version ?? '未登记'} · ID ${row.instanceId}`;
  }

  function instanceKey(group, service, ip, port, cluster) {
    return JSON.stringify([group, service, ip, Number(port), cluster || 'DEFAULT']);
  }

  function scopeMatches() {
    const namespace = state.namespaceId || 'public';
    return Boolean(state.connected && snapshot && state.instancesNamespace === namespace &&
      (snapshot.namespace || 'public') === namespace);
  }

  function match(instance) {
    if (stale || !scopeMatches()) return undefined;
    return instances.get(instanceKey(instance.groupName, instance.serviceName, instance.ip, instance.port, instance.clusterName));
  }

  function renderInfo(row) {
    if (!row) return '—';
    const [label, style] = stateLabels.get(rowState(row));
    const detail = row.error || row.status?.error;
    return `<span class="status ${style}">${label}</span>
      ${row.version ? `<small>版本 ${escapeHtml(row.version)}</small>` : ''}
      ${row.status?.activeCount != null ? `<small>处理中 ${escapeHtml(row.status.activeCount)}</small>` : ''}
      ${detail ? `<small>${escapeHtml(detail)}</small>` : ''}`;
  }

  function isLocked() {
    return state.loading || loading || stale || operating || dialog.open || !scopeMatches();
  }

  function canAct(action, targets) {
    return !isLocked() && targets.length > 0 && targets.every((row) => allowedActions(row).includes(action));
  }

  function renderActions(row, instanceKey) {
    if (!row) return '';
    return allowedActions(row).map((action) => `<button type="button" class="${action === 'PAUSE' ? 'danger' : 'success'}"
      data-action="mq-${action}" data-key="${escapeHtml(instanceKey)}" ${isLocked() ? 'disabled' : ''}>${actionLabel(action)}</button>`).join('');
  }

  function filters() {
    return {
      states: [...stateLabels],
      versions: scopeMatches() && !stale
        ? [...new Set([...instances.values()].map((row) => row?.version).filter(Boolean))].sort()
        : []
    };
  }

  function statusText() {
    if (!snapshot || stale) return '';
    if (!scopeMatches()) return `MQ 命名空间：${snapshot.namespace || 'public'}。连接对应的 Nacos 命名空间后显示消费状态。`;
    return `MQ 命名空间：${snapshot.namespace || 'public'} · 分组：${snapshot.group}`;
  }

  function schedulePoll() {
    clearTimeout(poll);
    if (stale || operating || dialog.open || !scopeMatches()) return;
    if (snapshot?.instances.some((row) => ['STARTING', 'DRAINING'].includes(row.status?.state))) {
      poll = setTimeout(() => refresh(true), 3000);
    }
  }

  async function refresh(automatic = false) {
    if (!state.connected || loading || operating || dialog.open) return;
    clearTimeout(poll);
    const connectionRevision = state.connectionRevision;
    loading = true;
    if (!automatic) message.textContent = '正在读取 MQ 状态…';
    renderTable();
    try {
      const data = await request('/mq-api/instances');
      if (connectionRevision !== state.connectionRevision) return;
      snapshot = data;
      instances = new Map();
      for (const row of snapshot.instances) {
        const key = instanceKey(snapshot.group, row.service, row.ip, row.port, row.cluster);
        instances.set(key, instances.has(key) ? undefined : row);
      }
      stale = false;
      const errors = snapshot.errors ?? [];
      message.textContent = errors.map(({ service, message }) => `${service} · ${message}`).join('；');
    } catch (error) {
      if (connectionRevision !== state.connectionRevision) return;
      stale = true;
      message.textContent = `MQ 读取失败：${error.message}`;
    } finally {
      if (connectionRevision === state.connectionRevision) {
        loading = false;
        renderFilters();
        renderTable();
        schedulePoll();
      }
    }
  }

  function actionLabel(action) {
    return action === 'PAUSE' ? '暂停消费' : '恢复消费';
  }

  function confirmAction(action, targets) {
    if (!canAct(action, targets)) return;
    clearTimeout(poll);
    confirmation = { action, targets };
    byId('confirm-title').textContent = `确认${actionLabel(action)}`;
    byId('confirm-scope').textContent = `命名空间 ${snapshot.namespace || '—'} · 分组 ${snapshot.group || '—'} · ${targets.length} 个实例`;
    byId('confirm-targets').replaceChildren(...targets.map((row) => {
      const item = document.createElement('li');
      item.textContent = displayTarget(row);
      return item;
    }));
    const button = byId('confirm-action');
    button.className = action === 'PAUSE' ? 'pause' : 'resume';
    button.textContent = actionLabel(action);
    dialog.returnValue = '';
    dialog.showModal();
  }

  async function runAction(action, targets) {
    const { namespace, group } = snapshot;
    const connectionRevision = state.connectionRevision;
    operating = true;
    renderTable();
    resultList.replaceChildren();
    results.hidden = false;
    for (const row of targets) {
      const item = document.createElement('li');
      const target = displayTarget(row);
      item.textContent = `${target} · 正在提交`;
      resultList.append(item);
      try {
        const { service, instanceId, version } = row;
        const status = await request('/mq-api/instances/action',
          { namespace, group, service, instanceId, version: version ?? null, action });
        if (connectionRevision !== state.connectionRevision) return;
        const [label] = stateLabels.get(status?.state) ?? ['已受理'];
        item.textContent = `${target} · ${label}${status?.error ? ` · ${status.error}` : ''}`;
        if (status?.error) item.className = 'error-text';
      } catch (error) {
        if (connectionRevision !== state.connectionRevision) return;
        item.className = 'error-text';
        item.textContent = `${target} · 请求失败：${error.message}`;
      }
    }
    state.selectedKeys.clear();
    operating = false;
    await refresh();
  }

  dialog.addEventListener('close', () => {
    if (dialog.returnValue === 'apply' && confirmation && canAct(confirmation.action, confirmation.targets)) {
      const { action, targets } = confirmation;
      confirmation = undefined;
      runAction(action, targets);
    } else {
      confirmation = undefined;
      schedulePoll();
    }
  });
  return { match, rowState, renderInfo, renderActions, filters, statusText, refresh, reset, canAct, confirmAction };
})();
