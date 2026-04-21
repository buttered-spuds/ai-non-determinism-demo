import { type Locator, type Page } from '@playwright/test';
import * as path from 'path';

export class DemoPage {
  constructor(private readonly page: Page) {}

  get runPromptButton(): Locator {
    return this.page.getByRole('button', { name: 'Run Prompt' });
  }

  get runTenTimesButton(): Locator {
    return this.page.getByRole('button', { name: 'Run 10 Times' });
  }

  /** ✕ Clear button scoped to the main demo section */
  get clearButton(): Locator {
    return this.page
      .getByRole('region', { name: /The Nondeterminism Simulator/ })
      .getByRole('button', { name: '✕ Clear' });
  }

  get askTheAiButton(): Locator {
    return this.page.getByRole('button', { name: 'Ask the AI' });
  }

  /** ✕ Clear button scoped to the hallucination section */
  get clearHallucinationButton(): Locator {
    return this.page
      .getByRole('region', { name: /Hallucination Demo/ })
      .getByRole('button', { name: '✕ Clear' });
  }

  get traditionalTestTab(): Locator {
    return this.page.getByRole('tab', { name: 'Traditional Test' });
  }

  get aiTestTab(): Locator {
    return this.page.getByRole('tab', { name: 'AI Test' });
  }

  get temperatureSlider(): Locator {
    return this.page.getByRole('slider', { name: 'Temperature' });
  }

  get outputCards(): Locator {
    return this.page.getByRole('article', { name: 'AI response output' });
  }

  get hallucinationCards(): Locator {
    return this.page.getByRole('article', { name: 'Hallucination response' });
  }

  get automationNavLink(): Locator {
    return this.page.getByRole('link', { name: 'How to Automate' });
  }

  cheatSheetPanel(rowNumber: number): Locator {
    return this.page.getByRole('region', { name: new RegExp(`${rowNumber} ·`) });
  }

  async goto(): Promise<void> {
    await this.page.goto('index.html');
  }

  async runPromptOnce(): Promise<void> {
    await this.runPromptButton.click();
  }

  async runPromptTenTimes(): Promise<void> {
    await this.runTenTimesButton.click();
  }

  async clearOutputs(): Promise<void> {
    await this.clearButton.click();
  }

  async askTheAi(): Promise<void> {
    await this.askTheAiButton.click();
  }

  /** Expands the nth cheat sheet accordion row (1-indexed). */
  async expandCheatSheetRow(rowNumber: number): Promise<void> {
    await this.page.getByRole('button', { name: new RegExp(`${rowNumber} ·`) }).click();
  }

  async switchToAiTestTab(): Promise<void> {
    await this.aiTestTab.click();
  }

  async switchToTraditionalTestTab(): Promise<void> {
    await this.traditionalTestTab.click();
  }

  async screenshot(name: string): Promise<void> {
    await this.page.screenshot({
      path: path.join('tests', 'screenshots', `${name}.png`),
    });
  }
}
