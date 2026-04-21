import { type Locator, type Page } from '@playwright/test';
import * as path from 'path';

export class AutomationPage {
  constructor(private readonly page: Page) {}

  get typescriptTab(): Locator {
    return this.page.getByRole('tab', { name: 'TypeScript' });
  }

  get dotnetTab(): Locator {
    return this.page.getByRole('tab', { name: '.NET (C#)' });
  }

  get pythonTab(): Locator {
    return this.page.getByRole('tab', { name: 'Python' });
  }

  get javascriptTab(): Locator {
    return this.page.getByRole('tab', { name: 'JavaScript' });
  }

  get demoNavLink(): Locator {
    return this.page.getByRole('link', { name: 'Demo' });
  }

  async goto(): Promise<void> {
    await this.page.goto('automation.html');
  }

  async switchToLanguageTab(
    language: 'TypeScript' | '.NET (C#)' | 'Python' | 'JavaScript',
  ): Promise<void> {
    await this.page.getByRole('tab', { name: language }).click();
  }

  /** Returns the tab panel for the given language. */
  languagePanel(language: 'TypeScript' | '.NET (C#)' | 'Python' | 'JavaScript'): Locator {
    return this.page.getByRole('tabpanel', { name: language });
  }

  async screenshot(name: string): Promise<void> {
    await this.page.screenshot({
      path: path.join('tests', 'screenshots', `${name}.png`),
    });
  }
}
