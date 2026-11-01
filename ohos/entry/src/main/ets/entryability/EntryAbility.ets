/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'Dragnet', '[Entry] set colorMode failed: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] Ability onCreate');
    this.ensureSeedRules();
  }

  // ensureSeedRules 把随包 rawfile 种子规则分发到 filesDir/rules（对应 Windows 侧
  // dragnetd -install 的种子分发；M4-R1：种子是分发包内可见文件，不编译进二进制，
  // 已有外部规则时不覆盖——用户可自行编辑/替换）。
  private async ensureSeedRules(): Promise<void> {
    const rulesDir: string = this.context.filesDir + '/rules';
    const seeds: string[] = ['starter.txt', 'protected-allow.txt'];
    try {
      if (!fs.accessSync(rulesDir)) {
        fs.mkdirSync(rulesDir);
      }
      for (const name of seeds) {
        const target: string = rulesDir + '/' + name;
        if (fs.accessSync(target)) {
          continue; // 已有文件不覆盖
        }
        const data: Uint8Array = await this.context.resourceManager.getRawFileContent('rules/' + name);
        const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, data.buffer);
        fs.closeSync(file);
        hilog.info(DOMAIN, 'Dragnet', 'seed %{public}s -> %{public}s (%{public}d bytes)', name, target, data.byteLength);
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'Dragnet', 'seed rules dispatch failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'Dragnet', '[Entry] load pages/Index failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'Dragnet', '[Entry] load pages/Index ok');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'Dragnet', '%{public}s', '[Entry] onBackground');
  }
}