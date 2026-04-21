import { test, expect } from '@playwright/test';
import { DemoPage } from './pages/DemoPage';
import { AutomationPage } from './pages/AutomationPage';

test('01 — demo page loads', async ({ page }) => {
  const demoPage = new DemoPage(page);
  await demoPage.goto();
  await expect(demoPage.runPromptButton).toBeVisible();
  await demoPage.screenshot('01-demo-loaded');
});

test('02 — run prompt once produces an output card', async ({ page }) => {
  const demoPage = new DemoPage(page);
  await demoPage.goto();
  await demoPage.runPromptOnce();
  await expect(demoPage.outputCards.first()).toBeVisible();
  await expect(demoPage.outputCards).toHaveCount(1);
  await demoPage.screenshot('02-single-output');
});

test('03 — run 10 times produces 10 output cards', async ({ page }) => {
  const demoPage = new DemoPage(page);
  await demoPage.goto();
  await demoPage.runPromptTenTimes();
  await expect(demoPage.outputCards).toHaveCount(10);
  await demoPage.screenshot('03-ten-outputs');
});

test('04 — hallucination demo produces a card', async ({ page }) => {
  const demoPage = new DemoPage(page);
  await demoPage.goto();
  await demoPage.askTheAi();
  await expect(demoPage.hallucinationCards.first()).toBeVisible();
  await demoPage.screenshot('04-hallucination');
});

test('05 — cheat sheet accordion opens', async ({ page }) => {
  const demoPage = new DemoPage(page);
  await demoPage.goto();
  await demoPage.expandCheatSheetRow(1);
  await expect(demoPage.cheatSheetPanel(1)).toBeVisible();
  await demoPage.screenshot('05-cheatsheet-expanded');
});

test('06 — automation page loads and tab switching works', async ({ page }) => {
  const automationPage = new AutomationPage(page);
  await automationPage.goto();
  await automationPage.switchToLanguageTab('Python');
  await expect(automationPage.languagePanel('Python')).toBeVisible();
  await automationPage.screenshot('06-automation-python-tab');
});
