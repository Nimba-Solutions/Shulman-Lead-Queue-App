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

    /**
     * Comprehensive workspace tab cold-start optimization
     */
    async warmUpConsoleApp() {
        if (this.component.isConsoleNavigation) {
            try {
                console.log('Console app detected - warming up workspace and navigation services...');
                
                // Pre-warm NavigationMixin with multiple URL types
                if (this.component.originalRecords && this.component.originalRecords.length > 0) {
                    const firstRecordId = this.component.originalRecords[0].Id;
                    if (firstRecordId && !firstRecordId.endsWith('-assigned')) {
                        const navigationPromises = [
                            // Standard record page (most common)
                            this.component[NavigationMixin.GenerateUrl]({
                                type: 'standard__recordPage',
                                attributes: {
                                    recordId: firstRecordId,
                                    objectApiName: 'litify_pm__Intake__c',
                                    actionName: 'view'
                                }
                            }),
                            // Edit record page to warm up form rendering
                            this.component[NavigationMixin.GenerateUrl]({
                                type: 'standard__recordPage',
                                attributes: {
                                    recordId: firstRecordId,
                                    objectApiName: 'litify_pm__Intake__c',
                                    actionName: 'edit'
                                }
                            })
                        ];
                        
                        Promise.all(navigationPromises).then(() => {
                            console.log('NavigationMixin warmed up with multiple URL types');
                        }).catch(error => {
                            console.debug('NavigationMixin warm-up skipped:', error);
                        });
                    }
                }
                
                // Pre-warm workspace API services
                setTimeout(() => {
                    this.preWarmWorkspaceServices();
                }, 100);
                
                // Preload record page resources
                setTimeout(() => {
                    this.preloadRecordPageResources();
                }, 300);
                
            } catch (error) {
                console.debug('Console warm-up skipped:', error);
            }
        }
    }

    /**
     * Pre-warm workspace API services
     */
    async preWarmWorkspaceServices() {
        try {
            if (this.component.workspaceApi) {
                // Access workspace API methods to trigger service initialization
                this.component.workspaceApi.isConsoleNavigation().then(() => {
                    console.log('Workspace API console detection warmed up');
                }).catch(error => {
                    console.debug('Workspace console detection warm-up skipped:', error);
                });
                
                // Pre-initialize workspace tab handling
                setTimeout(() => {
                    if (this.component.workspaceApi.getFocusedTabInfo) {
                        this.component.workspaceApi.getFocusedTabInfo().then(() => {
                            console.log('Workspace tab services warmed up');
                        }).catch(error => {
                            console.debug('Workspace tab services warm-up skipped:', error);
                        });
                    }
                }, 200);
            }
        } catch (error) {
            console.debug('Workspace services warm-up skipped:', error);
        }
    }

    /**
     * Preload critical resources for record page rendering
     */
    preloadRecordPageResources() {
        try {
            // Create invisible elements to trigger resource loading
            const preloadElements = [];
            
            const baseUrls = [
                '/lightning/r/litify_pm__Intake__c/',
                '/lightning/o/litify_pm__Intake__c/'
            ];
            
            baseUrls.forEach(url => {
                const link = document.createElement('link');
                link.rel = 'dns-prefetch';
                link.href = url;
                document.head.appendChild(link);
                preloadElements.push(link);
            });
            
            // Clean up preload elements after 3 seconds
            setTimeout(() => {
                preloadElements.forEach(element => {
                    if (element.parentNode) {
                        element.parentNode.removeChild(element);
                    }
                });
                console.log('Record page resources preloaded');
            }, 3000);
            
        } catch (error) {
            console.debug('Resource preload skipped:', error);
        }
    }

    /**
     * Warm up with record data
     */
    async warmUpWithRecords() {
        if (this.component.isConsoleNavigation && this.component.originalRecords && this.component.originalRecords.length > 0) {
            try {
                const sampleRecord = this.component.originalRecords.find(record => 
                    record.Id && !record.Id.endsWith('-assigned')
                );
                
                if (sampleRecord) {
                    console.log('Warming up console navigation with sample record...');
                    
                    this.component[NavigationMixin.GenerateUrl]({
                        type: 'standard__recordPage',
                        attributes: {
                            recordId: sampleRecord.Id,
                            objectApiName: 'litify_pm__Intake__c',
                            actionName: 'view'
                        }
                    }).then(() => {
                        console.log('Console navigation warmed up successfully');
                    }).catch(error => {
                        console.debug('Navigation warm-up optional, skipped:', error);
                    });
                }
            } catch (error) {
                console.debug('Console warm-up with records skipped:', error);
            }
        }
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
            const tabInfo = await openTab({
                recordId: recordId,
                focus: true,
                url: `/lightning/r/litify_pm__Intake__c/${recordId}/view?layout=S_H_Record_Intake_Active_Intake`
            });
            console.log('Workspace tab opened:', tabInfo.tabId);
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