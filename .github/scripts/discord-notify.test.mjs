import assert from 'node:assert/strict';
import test from 'node:test';

import {
  ciStartNotifications,
  enrichWorkflowResult,
  notification,
  publicationSuccessNotification,
  reportsRun,
  send,
  stageResultNotification,
  stageStartNotification,
} from './discord-notify.mjs';

const repo = { full_name: 'SlippinDylan/Cellar' };
const sha = 'a'.repeat(40);
const env = {
  GITHUB_REPOSITORY: 'SlippinDylan/Cellar',
  GITHUB_REF_NAME: 'main',
  GITHUB_SHA: sha,
  GITHUB_RUN_ID: '42',
  GITHUB_EVENT_NAME: 'push',
  GITHUB_RUN_ATTEMPT: '1',
};

test('formats collaboration events with escaped text and disabled mentions', () => {
  const push = notification('push', {
    repository: repo,
    ref: 'refs/heads/feat/test',
    head_commit: { message: 'fix @everyone *bold*' },
  });
  assert.equal(push.username, 'Cellar');
  assert.deepEqual(push.allowed_mentions, { parse: [] });
  assert.match(push.embeds[0].title, /Cellar · 代码已推送/);
  assert.match(push.embeds[0].description, /\\@everyone \\\*bold\\\*/);

  const pr = notification('pull_request_target', {
    repository: repo,
    action: 'closed',
    number: 12,
    pull_request: { title: 'Ship 1.0', merged: true },
  });
  assert.equal(pr.embeds[0].title, 'Cellar · PR 已合并');
  assert.equal(pr.embeds[0].url, 'https://github.com/SlippinDylan/Cellar/pull/12');

  const reviewComment = notification('pull_request_review_comment', {
    repository: repo,
    pull_request: { number: 12, title: 'Ship 1.0' },
  });
  assert.equal(reviewComment.embeds[0].title, 'Cellar · PR 有代码评论');
});

test('orders main push and CI start notifications and skips duplicate CI success in workflow_run', () => {
  const startPayloads = ciStartNotifications(
    { repository: repo, ref: 'refs/heads/main', head_commit: { message: 'feat: sync' } },
    env,
  );
  assert.equal(startPayloads.length, 2);
  assert.equal(startPayloads[0].embeds[0].title, 'Cellar · 代码已推送');
  assert.equal(startPayloads[1].embeds[0].title, 'Cellar · 检查已开始');

  const ciDone = notification('workflow_run', {
    action: 'completed',
    repository: repo,
    workflow_run: {
      id: 42,
      name: 'CI',
      event: 'push',
      head_branch: 'main',
      head_sha: sha,
      run_number: 5,
      conclusion: 'success',
      stageConclusion: 'success',
    },
  });
  assert.equal(ciDone, null);

  const ciFailed = notification('workflow_run', {
    action: 'completed',
    repository: repo,
    workflow_run: {
      id: 42,
      name: 'CI',
      event: 'push',
      head_branch: 'main',
      head_sha: sha,
      run_number: 5,
      conclusion: 'failure',
      stageConclusion: 'failure',
    },
  });
  assert.equal(ciFailed.embeds[0].title, 'Cellar · 检查失败');
});

test('builds distinct stage notifications for packaging, publication, and distribution sync', () => {
  assert.equal(stageStartNotification('Release', env).embeds[0].title, 'Cellar · 打包已开始');
  assert.equal(stageResultNotification('Release', 'success', env).embeds[0].title, 'Cellar · 打包成功');
  assert.equal(publicationSuccessNotification(env).embeds[0].title, 'Cellar · 发行成功');
  assert.equal(
    stageStartNotification('Publish Distribution Metadata', env).embeds[0].title,
    'Cellar · Sparkle 与 Homebrew 同步已开始',
  );
  assert.equal(
    stageResultNotification('Publish Distribution Metadata', 'success', env).embeds[0].title,
    'Cellar · Sparkle 与 Homebrew 同步成功',
  );
});

test('enriches workflow_run stage conclusions and ignores skipped release runs', async () => {
  const event = {
    action: 'completed',
    repository: repo,
    workflow_run: {
      id: 99,
      run_attempt: 1,
      name: 'Release',
      event: 'workflow_run',
      head_branch: 'main',
      head_sha: sha,
      run_number: 9,
      conclusion: 'success',
    },
  };
  assert.equal(reportsRun(event), true);
  await enrichWorkflowResult(event, 'token', async () => ({
    ok: true,
    json: async () => ({
      total_count: 2,
      jobs: [
        { name: 'Plan release', conclusion: 'success' },
        { name: 'Publish GitHub Release', conclusion: 'skipped' },
      ],
    }),
  }));
  assert.equal(notification('workflow_run', event), null);

  const verifyFailed = {
    action: 'completed',
    repository: repo,
    workflow_run: {
      id: 100,
      run_attempt: 1,
      name: 'Release',
      event: 'workflow_run',
      head_branch: 'main',
      head_sha: sha,
      run_number: 10,
      conclusion: 'failure',
    },
  };
  await enrichWorkflowResult(verifyFailed, 'token', async () => ({
    ok: true,
    json: async () => ({
      total_count: 3,
      jobs: [
        { name: 'Plan release', conclusion: 'success' },
        { name: 'Build signed draft release', conclusion: 'skipped' },
        { name: 'Verify draft release', conclusion: 'failure' },
      ],
    }),
  }));
  assert.equal(notification('workflow_run', verifyFailed).embeds[0].title, 'Cellar · 打包校验失败');

  const distSuccess = {
    action: 'completed',
    repository: repo,
    workflow_run: {
      id: 101,
      run_attempt: 1,
      name: 'Publish Distribution Metadata',
      event: 'workflow_dispatch',
      head_branch: 'main',
      head_sha: sha,
      run_number: 11,
      conclusion: 'success',
      stageConclusion: 'success',
    },
  };
  assert.equal(notification('workflow_run', distSuccess), null);
});

test('validates Discord webhook URLs without echoing secrets on error', async () => {
  const secret = 'https://example.invalid/api/webhooks/123/secret-token';
  await assert.rejects(
    () => send({ embeds: [] }, secret),
    error => !error.message.includes('secret-token'),
  );

  let calledUrl;
  await send({ embeds: [] }, 'https://discord.com/api/webhooks/123/abc', async (url) => {
    calledUrl = String(url);
    return { ok: true };
  });
  assert.equal(calledUrl, 'https://discord.com/api/webhooks/123/abc?wait=true');
});
