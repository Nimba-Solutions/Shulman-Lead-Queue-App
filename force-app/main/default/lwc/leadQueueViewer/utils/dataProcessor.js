/**
 * Data processing utilities for Lead Queue
 * Handles queue data processing, filtering, and state management
 */
import { SharedUtils } from './sharedUtils';

export class DataProcessor {
    
    constructor(component) {
        this.component = component;
    }

    /**
     * Process queue response data from server
     */
    processQueueResponse(data) {
        // Validate data structure
        if (!data || typeof data !== 'object') {
            console.error('Invalid data structure received:', data);
            this.resetToEmptyState();
            return;
        }
        
        // Safe assignment with fallbacks - store original stats and keep them fixed
        this.component.originalStats = data.stats || { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        // queueStats should always show original values, never update with filters
        this.component.queueStats = { ...this.component.originalStats };
        this.component.filterOptions = data.filters || { statusOptions: [], caseTypeOptions: [] };
        
        // Validate records array
        if (!Array.isArray(data.records)) {
            console.error('Records is not an array:', data.records);
            this.component.records = [];
            return;
        }
        
        // Store original data for filter state management
        this.component.originalRecords = data.records
            .filter(queueRecord => queueRecord && queueRecord.record) // Filter out invalid entries
            .map((queueRecord, index) => {
                const record = queueRecord.record;
                const originalRecordId = record.Id;
                return {
                    Id: queueRecord.assignedTo ? (record.Id + '-assigned') : record.Id,
                    Name: record.Name || 'Unknown',
                    litify_pm__Display_Name__c: record.litify_pm__Display_Name__c || '',
                    Referred_By_Name__c: record.Referred_By_Name__c || '',
                    Status: record.litify_pm__Status__c || '',
                    CaseType: record.Case_Type_Reporting__c || '',
                    Qualification_Status__c: record.Qualification_Status__c || '',
                    callDateTime: SharedUtils.formatCallDateTime(record.Call_at_Date__c),
                    Phone: record.litify_pm__Phone__c || '',
                    assignedTo: queueRecord.assignedTo || '',
                    assignmentTimer: this.component.timerManager.getRecordAssignmentTimer(originalRecordId, queueRecord.assignedTo, queueRecord.assignedTimestamp),
                    assignmentTimestamp: queueRecord.assignedTimestamp,
                    priorityRank: index + 1,
                    recordUrl: `/lightning/r/litify_pm__Intake__c/${originalRecordId}/view`,
                };
            });
        
        // Create working copy for display
        this.component.records = [...this.component.originalRecords];
        
        // Apply current tile filter if active
        this.applyClientSideFilter();
        
        // Warm up console navigation now that we have records
        this.component.consoleNavigation.warmUpWithRecords();
    }

    /**
     * Reset component to empty state
     */
    resetToEmptyState() {
        this.component.records = [];
        this.component.originalRecords = [];
        this.component.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.component.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.component.filterOptions = { statusOptions: [], caseTypeOptions: [] };
    }

    /**
     * Apply client-side filtering based on active tile filter
     */
    applyClientSideFilter() {
        if (this.component.activeTileFilter === 'highPriority') {
            this.component.records = this.component.originalRecords.filter(record => 
                record.Status === 'Intake Scheduled' || record.Status === 'Lead Generated'
            );
        } else if (this.component.activeTileFilter === 'inContact') {
            this.component.records = this.component.originalRecords.filter(record => 
                record.Status === 'In Contact/Under Review' || record.Status === 'Questionnaire' || record.Status === 'Missed Appointment'
            );
        } else if (this.component.activeTileFilter === 'noContact') {
            this.component.records = this.component.originalRecords.filter(record => 
                record.Status === 'Attempting to Contact'
            );
        } else if (this.component.activeTileFilter === 'retainerSent') {
            this.component.records = this.component.originalRecords.filter(record => 
                record.Status === 'Intake Package Sent'
            );
        } else {
            // No filter active, show all original records
            this.component.records = [...this.component.originalRecords];
        }
    }

    /**
     * Apply tile filter
     */
    async applyTileFilter() {
        // All tiles now use client-side filtering for consistency
        this.applyClientSideFilter();
    }

    /**
     * Clear all filters
     */
    clearFilters() {
        // Increment request ID to invalidate any pending responses
        this.component.filterRequestId++;
        
        this.component.statusFilter = '';
        this.component.caseTypeFilter = '';
        this.component.dueDateFilter = '';
        this.component.activeTileFilter = null;
        
        // Restore original records and stats
        if (this.component.originalRecords.length > 0) {
            this.component.records = [...this.component.originalRecords];
        }
        
        this.updateTileVisualState();
    }

    /**
     * Update visual state of tiles
     */
    updateTileVisualState() {
        // Update tile CSS classes for visual indication
        const tiles = this.component.template.querySelectorAll('.stat-card[data-filter]');
        tiles.forEach(tile => {
            const filterType = tile.dataset.filter;
            if (filterType === this.component.activeTileFilter) {
                tile.classList.add('active-filter');
            } else {
                tile.classList.remove('active-filter');
            }
        });
    }

    /**
     * Get table column configuration
     */
    getTableColumns() {
        return [
            {
                label: 'Priority',
                fieldName: 'priorityRank',
                type: 'number',
                cellAttributes: { alignment: 'center' },
                initialWidth: 90
            },
            {
                label: 'Name',
                type: 'url',
                typeAttributes: {
                    label: { fieldName: 'litify_pm__Display_Name__c' },
                    target: '_self'
                },
                fieldName: 'recordUrl',
                cellAttributes: { 
                    alignment: 'left',
                    class: 'name-url-cell'
                },
                initialWidth: 400
            },
            {
                label: 'Referred By',
                fieldName: 'Referred_By_Name__c',
                type: 'text'
            },
            {
                label: 'Status',
                fieldName: 'Status',
                type: 'text',
            },
            {
                label: 'Case Type',
                fieldName: 'CaseType',
                type: 'text',
            },
            {
                label: 'Qualification Status',
                fieldName: 'Qualification_Status__c',
                type: 'text',
                cellAttributes: { alignment: 'left' }
            },
            {
                label: 'Call Date and Time',
                fieldName: 'callDateTime',
                type: 'text',
                sortable: true,
            },
            {
                label: 'Phone',
                fieldName: 'Phone',
                type: 'phone',
                initialWidth: 130
            },
            {
                label: 'Currently Assigned',
                fieldName: 'assignedTo',
                type: 'text',
            },
            {
                label: 'Time Assigned',
                fieldName: 'assignmentTimer',
                type: 'text',
                cellAttributes: { alignment: 'center' },
                initialWidth: 80
            },
            {
                type: 'action',
                typeAttributes: {
                    rowActions: [
                        { label: 'Assign to Me', name: 'assign', iconName: 'utility:user' }
                    ]
                }
            }
        ];
    }
}