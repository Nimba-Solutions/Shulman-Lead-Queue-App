/**
 * Console Navigation utilities for Lead Queue
 * Handles workspace tab optimization and console-specific navigation
 */
import { NavigationMixin } from 'lightning/navigation';
import { openTab } from 'lightning/platformWorkspaceApi';

export class ConsoleNavigationManager {
    
    constructor(component) {
        this.component = component;
    }

    warmUpConsoleApp() {
        // No-op for small orgs: rely on on-demand navigation without preloading.
    }

    /**
     * Navigate to record with console optimization
     */
    navigateToRecord(recordId) {
        if (this.component.isConsoleNavigation) {
            this.openWorkspaceTab(recordId);
        } else {
            this.fallbackNavigation(recordId);
        }
    }

    /**
     * Open record in workspace tab
     */
    async openWorkspaceTab(recordId) {
        try {
            await openTab({
                recordId: recordId,
                focus: true,
                url: `/lightning/r/litify_pm__Intake__c/${recordId}/view?layout=S_H_Record_Intake_Active_Intake`
            });
        } catch (error) {
            console.error('Failed to open workspace tab for record ' + recordId + ':', error);
            this.fallbackNavigation(recordId);
        }
    }

    /**
     * Fallback navigation for non-console environments
     */
    fallbackNavigation(recordId) {
        this.component[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                objectApiName: 'litify_pm__Intake__c',
                actionName: 'view'
            },
            state: {
                layout: 'S_H_Record_Intake_Active_Intake'
            }
        });
    }
}
