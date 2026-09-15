import { expect, test } from '@playwright/test';

test('light OFF and scenes send acknowledged commands and update reported state', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  const card = page.getByRole('article', { name: 'Ensuite', exact: true });
  await expect(page.getByLabel('Controller connection: Connected')).toBeVisible();
  await card.getByRole('button', { name: 'Turn off Ensuite' }).click();
  await expect(card.locator('.state-pair')).toContainText('Off');
  await expect(card.getByRole('status')).toHaveCount(0);
  await card.getByRole('button', { name: 'Recall scene 2 in Ensuite' }).click();
  await expect(card.locator('.state-pair')).toContainText('Scene 2');
  await expect(card.locator('.state-pair')).toContainText('On');
  await expect(card.getByRole('status')).toHaveCount(0);
  await card.getByText('Lights & automation').click();
  await expect(card.getByText('Motion enabled')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Event Log' })).toHaveCount(0);
  await page.screenshot({ path: 'test-results/lights-desktop.png', fullPage: true });
  expect(errors).toEqual([]);
});

test('plugs expose explicit on and off actions', async ({ page }) => {
  await page.goto('/#plugs');
  const card = page.getByRole('article', { name: 'Printer' });
  await expect(card.getByRole('button', { name: 'Turn off Printer' })).toBeEnabled();
  await card.getByRole('button', { name: 'Turn off Printer' }).click();
  await expect(card.locator('.state-pair')).toContainText('Off');
  await expect(card.getByRole('status')).toHaveCount(0);
  await card.getByRole('button', { name: 'Turn on Printer' }).click();
  await expect(card.locator('.state-pair')).toContainText('On');
  await expect(card.getByRole('status')).toHaveCount(0);
});

test('heating retains target, actual, freshness, zero battery and per-valve history', async ({ page }) => {
  await page.goto('/#heating');
  await expect(page.getByRole('img', { name: /temperature and setpoint history/ })).toHaveCount(2);
  await expect(page.getByText('Battery 0%')).toBeVisible();
  await expect(page.getByText('Open-window hold is active.')).toBeVisible();
  expect(await page.locator('.chart-actual').first().getAttribute('d')).toContain('L');
  await page.screenshot({ path: 'test-results/heating-desktop.png', fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.screenshot({ path: 'test-results/heating-mobile.png', fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test('connection interruption pauses controls and recovers with a new snapshot', async ({ page, context }) => {
  await page.goto('/');
  const off = page.getByRole('button', { name: 'Turn off Ensuite' });
  await expect(off).toBeEnabled();
  await context.setOffline(true);
  await expect(off).toBeDisabled({ timeout: 20_000 });
  await context.setOffline(false);
  await expect(off).toBeEnabled({ timeout: 20_000 });
  await off.click();
  await expect(page.getByRole('article', { name: 'Ensuite', exact: true }).locator('.state-pair')).toContainText('Off');
  await expect(page.getByRole('status')).toHaveCount(0);
});
