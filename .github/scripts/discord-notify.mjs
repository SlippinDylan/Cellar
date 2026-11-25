import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const clean = value => String(value ?? '').replace(/\s+/g, ' ').slice(0, 240);
const escape = value => clean(value).replace(/([\\`*_~|<>@\[\]])/g, '\\$1');

const workflows = {
  CI: { label: '检查', job: 'Test and build Cellar' },
  Release: { label: '发行', job: 'Publish GitHub Release' },
  'Publish Distribution Metadata': { label: 'Sparkle 与 Homebrew 同步', job: 'Sign appcast and update Homebrew tap' },
};

const conclusions = {
  success: '成功',
  failure: '失败',
  cancelled: '已取消',
  timed_out: '超时',
  skipped: '已跳过',
  action_required: '需要人工处理',
  neutral: '无成功或失败结论',
  stale: '已过期',
};

function repository(event) {
  const name = event.repository?.full_name;
  if (!/^[\w.-]+\/[\w.-]+$/.test(name ?? '')) throw new Error('Invalid repository.');
  return name;
}

function identifier(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error('Invalid GitHub event identifier.');
  return value;
}

export function reportsRun(event) {
  const run = event.workflow_run;
  return event.action === 'completed'
    && Object.hasOwn(workflows, run.name)
    && run.head_branch === 'main'
    && (run.name === 'CI'
      ? ['push', 'workflow_dispatch'].includes(run.event)
      : ['push', 'workflow_dispatch', 'workflow_run', 'release'].includes(run.event));
}

export function notification(eventName, event) {
  const repo = repository(event);
  const base = `https://github.com/${repo}`;
  let title, detail, url = base, color = 0x5865f2;

  switch (eventName) {
    case 'push':
      title = event.deleted ? '分支已删除' : '代码已推送';
      detail = `${event.ref} · ${event.head_commit?.message ?? ''}`;
      break;
    case 'pull_request_target':
      title = event.pull_request.merged ? 'PR 已合并' : `PR ${event.action}`;
      detail = `#${event.number} ${event.pull_request.title}`;
      url = `${base}/pull/${identifier(event.number)}`;
      break;
    case 'issues':
    case 'issue_comment': {
      const kind = event.issue.pull_request ? 'PR' : 'Issue';
      title = eventName === 'issue_comment' ? `${kind} 有新评论` : `${kind} ${event.action}`;
      detail = `#${event.issue.number} ${event.issue.title}`;
      url = `${base}/${kind === 'PR' ? 'pull' : 'issues'}/${identifier(event.issue.number)}`;
      break;
    }
    case 'pull_request_review':
    case 'pull_request_review_comment':
      title = eventName === 'pull_request_review_comment' ? 'PR 有代码评论' : `PR 审核：${event.review.state}`;
      detail = `#${event.pull_request.number} ${event.pull_request.title}`;
      url = `${base}/pull/${identifier(event.pull_request.number)}`;
      break;
    case 'workflow_run': {
      const run = event.workflow_run;
      if (!reportsRun(event)) return null;
      if (run.name === 'CI' && run.conclusion === 'success') return null;

      const published = run.name === 'Release' && run.stageConclusion === 'success';
      let result = published
        ? 'success'
        : run.conclusion === 'success' && run.name !== 'CI'
          ? run.stageConclusion
          : run.conclusion;
      let label = workflows[run.name].label;

      if (published) return null;

      if (run.name === 'Release') {
        if (run.buildConclusion && !['success', 'skipped'].includes(run.buildConclusion)) {
          label = '打包';
          result = run.buildConclusion;
        } else if (run.verifyConclusion && !['success', 'skipped'].includes(run.verifyConclusion)) {
          label = '打包校验';
          result = run.verifyConclusion;
        } else if (run.distributionConclusion && !['success', 'skipped'].includes(run.distributionConclusion)) {
          label = 'Sparkle 与 Homebrew 同步';
          result = run.distributionConclusion;
        } else if (run.gateConclusion && !['success', 'skipped'].includes(run.gateConclusion)) {
          label = '发行前检查';
          result = run.gateConclusion;
        } else if (run.stageConclusion && run.stageConclusion !== 'skipped') {
          result = run.stageConclusion;
        } else if (run.conclusion !== 'success') {
          result = run.conclusion;
        } else {
          return null;
        }
      }

      if (run.name === 'Publish Distribution Metadata' && ['success', 'skipped'].includes(run.stageConclusion)) return null;
      if (!Object.hasOwn(conclusions, result)) throw new Error('Missing or unknown workflow stage conclusion.');

      title = `${label}${conclusions[result]}`;
      detail = `${run.head_branch} · ${String(run.head_sha).slice(0, 7)} · #${run.run_number}`;
      if (run.name === 'CI' && run.stageConclusion === 'skipped') detail += ' · App 编译已跳过';
      url = `${base}/actions/runs/${identifier(run.id)}`;
      color = result === 'success' ? 0x57f287 : ['failure', 'timed_out'].includes(result) ? 0xed4245 : 0x99aab5;
      break;
    }
    case 'release':
      return null;
    default:
      return null;
  }

  return {
    username: 'Cellar',
    allowed_mentions: { parse: [] },
    embeds: [{
      title: `Cellar · ${escape(title)}`,
      description: `${escape(repo)}\n${escape(detail)}`,
      url,
      color,
    }],
  };
}

export function stageStartNotification(name, environment) {
  return stageNotification(name, 'start', environment);
}

export function stageResultNotification(name, result, environment) {
  if (!['success', 'failure'].includes(result)) throw new Error('Unknown stage result.');
  return stageNotification(name, result, environment);
}

export function publicationSuccessNotification(environment) {
  return stageNotification('Release', 'success', environment, '发行');
}

function stageNotification(name, result, environment, label) {
  if (!Object.hasOwn(workflows, name)) throw new Error('Unknown workflow stage.');
  const sourceSHA = environment.RELEASE_SHA ?? environment.TESTED_SHA ?? environment.GITHUB_SHA;
  if (!/^[a-f0-9]{40}$/.test(sourceSHA ?? '')) throw new Error('Invalid build commit SHA.');
  const runId = Number(environment.GITHUB_RUN_ID);
  identifier(runId);
  const repo = repository({ repository: { full_name: environment.GITHUB_REPOSITORY } });
  const labels = {
    CI: '检查',
    Release: '打包',
    'Publish Distribution Metadata': 'Sparkle 与 Homebrew 同步',
  };
  return {
    username: 'Cellar',
    allowed_mentions: { parse: [] },
    embeds: [{
      title: `Cellar · ${label ?? labels[name]}${result === 'start' ? '已开始' : conclusions[result]}`,
      description: `${escape(repo)}\n${escape(environment.GITHUB_REF_NAME)} · ${sourceSHA.slice(0, 7)}`,
      url: `https://github.com/${repo}/actions/runs/${runId}`,
      color: result === 'start' ? 0x5865f2 : result === 'success' ? 0x57f287 : 0xed4245,
    }],
  };
}

export function ciStartNotifications(event, environment) {
  const payloads = [];
  if (environment.GITHUB_EVENT_NAME === 'push' && environment.GITHUB_RUN_ATTEMPT === '1') {
    payloads.push(notification('push', event));
  }
  payloads.push(stageStartNotification('CI', environment));
  return payloads;
}

export async function enrichWorkflowResult(event, token, fetcher = fetch) {
  const run = event.workflow_run;
  if (!reportsRun(event)) return;
  if (!token) throw new Error('Missing Actions token for workflow result.');
  const endpoint = `https://api.github.com/repos/${repository(event)}/actions/runs/${identifier(run.id)}/attempts/${identifier(run.run_attempt)}/jobs?per_page=100`;
  let response;
  try {
    response = await fetcher(endpoint, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(10000),
      redirect: 'error',
    });
  } catch {
    throw new Error('Cannot read workflow jobs from GitHub.');
  }
  if (!response.ok) throw new Error(`Cannot read workflow jobs: HTTP ${response.status}.`);
  const body = await response.json();
  if (!Array.isArray(body.jobs) || !Number.isSafeInteger(body.total_count) || body.total_count !== body.jobs.length || body.total_count > 100) {
    throw new Error('Incomplete workflow jobs response.');
  }

  const jobs = body.jobs.filter(job => job.name === workflows[run.name].job);
  if (jobs.length === 0 && run.conclusion !== 'success' && run.name !== 'Release') return;
  if (
    (jobs.length !== 1 && !(run.name === 'Release' && jobs.length === 0 && run.conclusion !== 'success'))
    || (jobs.length === 1 && !Object.hasOwn(conclusions, jobs[0].conclusion))
  ) {
    throw new Error('Expected exactly one completed workflow stage.');
  }
  if (run.conclusion === 'success' && !['success', 'skipped', 'neutral'].includes(jobs[0].conclusion)) {
    throw new Error('Workflow success disagrees with its stage result.');
  }
  if (jobs.length === 1) run.stageConclusion = jobs[0].conclusion;

  if (run.name === 'Release') {
    const stages = [
      ['buildConclusion', 'Build signed draft release'],
      ['verifyConclusion', 'Verify draft release'],
      ['gateConclusion', 'Plan release'],
      ['distributionConclusion', 'Publish distribution metadata / Sign appcast and update Homebrew tap'],
    ];
    for (const [property, name] of stages) {
      const matched = body.jobs.filter(job => job.name === name);
      if (matched.length > 1 || (matched.length === 1 && !Object.hasOwn(conclusions, matched[0].conclusion))) {
        throw new Error('Expected at most one completed release stage.');
      }
      if (matched.length === 1) run[property] = matched[0].conclusion;
    }
  }
}

export async function send(payload, webhook, fetcher = fetch) {
  let endpoint;
  try {
    endpoint = new URL(webhook);
  } catch {
    throw new Error('Invalid Discord webhook configuration.');
  }
  if (
    endpoint.protocol !== 'https:'
    || !['discord.com', 'discordapp.com'].includes(endpoint.hostname)
    || !endpoint.pathname.startsWith('/api/webhooks/')
  ) {
    throw new Error('Invalid Discord webhook configuration.');
  }
  endpoint.searchParams.set('wait', 'true');
  let response;
  try {
    response = await fetcher(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10000),
      redirect: 'error',
    });
  } catch {
    throw new Error('Discord request failed.');
  }
  if (!response.ok) throw new Error(`Discord returned HTTP ${response.status}.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    let payloads;
    const args = process.argv.slice(2);
    if (args.length) {
      if (args.length === 1 && args[0] === '--ci-start') {
        const event = process.env.GITHUB_EVENT_NAME === 'push'
          ? JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8'))
          : {};
        payloads = ciStartNotifications(event, process.env);
      } else if (args.length === 1 && args[0] === '--publication-success') {
        payloads = [publicationSuccessNotification(process.env)];
      } else if (args.length === 2 && args[0] === '--stage-start') {
        payloads = [stageStartNotification(args[1], process.env)];
      } else if (args.length === 3 && args[0] === '--stage-result') {
        payloads = [stageResultNotification(args[1], args[2], process.env)];
      } else {
        throw new Error('Use --ci-start, --publication-success, --stage-start <workflow>, --stage-result <workflow> <success|failure>, or no arguments.');
      }
    } else {
      const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, 'utf8'));
      if (process.env.GITHUB_EVENT_NAME === 'workflow_run') {
        await enrichWorkflowResult(event, process.env.GITHUB_TOKEN);
      }
      payloads = [notification(process.env.GITHUB_EVENT_NAME, event)];
    }
    for (const payload of payloads) {
      if (payload) await send(payload, process.env.DISCORD_WEBHOOK_URL);
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
