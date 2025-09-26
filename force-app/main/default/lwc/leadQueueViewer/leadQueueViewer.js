import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { IsConsoleNavigation, openTab, focusTab } from 'lightning/platformWorkspaceApi';
import { refreshApex } from '@salesforce/apex';
import getQueueData from '@salesforce/apex/LeadQueueService.getQueueData';
import assignRecord from '@salesforce/apex/LeadQueueService.assignRecord';
import assignNextAvailableRecord from '@salesforce/apex/LeadQueueService.assignNextAvailableRecord';
import releaseUserAssignments from '@salesforce/apex/LeadQueueService.releaseUserAssignments';
import getUserAssignedRecordIds from '@salesforce/apex/LeadQueueService.getUserAssignedRecordIds';

export default class LeadQueueViewer extends NavigationMixin(LightningElement) {
    static HIGH_PRIORITY_THRESHOLD = 22;
    static MEDIUM_PRIORITY_THRESHOLD = 55;
    static REFRESH_INTERVAL = 30000;
    
    // Utility bar mode support
    @api utilityMode = false;
    statusFilter = '';
    caseTypeFilter = '';
    dueDateFilter = '';
    activeTileFilter = null;
    
    @track queueStats = {
        totalRecords: 0,
        highPriorityCount: 0,
        inContactCount: 0,
        noContactCount: 0,
        retainerSentCount: 0
    };
    
    // Store original stats to always show total values on tiles
    originalStats = {
        totalRecords: 0,
        highPriorityCount: 0,
        inContactCount: 0,
        noContactCount: 0,
        retainerSentCount: 0
    };
    
    @track filterOptions = {
        statusOptions: [],
        caseTypeOptions: []
    };
    
    @track hasAssignments = false;
    @track records = [];
    originalRecords = [];
    @track currentTime = new Date();
    isAssigning = false;
    isReleasing = false;
    @track showScheduledCalls = false;
    
    refreshInterval;
    wiredQueueResult;
    filterTimeout;
    filterRequestId = 0;
    
    // Console navigation detection
    @wire(IsConsoleNavigation) isConsoleNavigation;
    
    dueDateOptions = [
        { label: 'All Dates', value: '' },
        { label: 'Due Today', value: 'today' },
        { label: 'Due This Week', value: 'thisWeek' },
        { label: 'Due Next Week', value: 'nextWeek' }
    ];
    
    get tableColumns() {
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
                fieldName: 'QualificationStatus',
                type: 'text',
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
                label: 'Timer',
                fieldName: 'assignmentTimer',
                type: 'text',
                initialWidth: 120
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
    
    @wire(getQueueData, { 
        statusFilter: '$statusFilter', 
        caseTypeFilter: '$caseTypeFilter', 
        dueDateFilter: '$dueDateFilter',
        showScheduledCalls: '$showScheduledCalls'
    })
    wiredQueue(result) {
        this.wiredQueueResult = result;
        
        // Only process if this is the most recent request
        const currentRequestId = this.filterRequestId;
        
        if (result.data) {
            // Use requestAnimationFrame to ensure this is processed after any pending filter updates
            requestAnimationFrame(() => {
                if (this.filterRequestId === currentRequestId) {
                    this.processQueueResponse(result.data);
                }
            });
        } else if (result.error) {
            requestAnimationFrame(() => {
                if (this.filterRequestId === currentRequestId) {
                    // Clear data arrays but preserve user filter state for better UX
                    this.records = [];
                    this.originalRecords = [];
                    this.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
                    this.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
                    this.filterOptions = { statusOptions: [], caseTypeOptions: [] };
                    
                    // Preserve user selections: statusFilter, caseTypeFilter, dueDateFilter, activeTileFilter remain intact
                    // Only clear operational state, not user preferences
                    this.hasAssignments = false;
                    this.isAssigning = false;
                    this.isReleasing = false;
                    
                    this.showToast('Error', 'Failed to load lead queue: ' + this.getErrorMessage(result.error), 'error');
                }
            });
        }
    }
    
    async warmUpConsoleApp() {
        // Comprehensive workspace tab cold-start optimization
        if (this.isConsoleNavigation) {
            try {
                console.log('Console app detected - warming up workspace and navigation services...');
                
                // 1. Pre-warm NavigationMixin with multiple URL types to initialize routing
                if (this.originalRecords && this.originalRecords.length > 0) {
                    const firstRecordId = this.originalRecords[0].Id;
                    if (firstRecordId && !firstRecordId.endsWith('-assigned')) {
                        // Generate multiple URL types to warm up navigation service
                        const navigationPromises = [
                            // Standard record page (most common)
                            this[NavigationMixin.GenerateUrl]({
                                type: 'standard__recordPage',
                                attributes: {
                                    recordId: firstRecordId,
                                    objectApiName: 'litify_pm__Intake__c',
                                    actionName: 'view'
                                }
                            }),
                            // Edit record page to warm up form rendering
                            this[NavigationMixin.GenerateUrl]({
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
                
                // 2. Pre-warm workspace API by accessing basic workspace properties
                setTimeout(() => {
                    this.preWarmWorkspaceServices();
                }, 100);
                
                // 3. Preload record page resources
                setTimeout(() => {
                    this.preloadRecordPageResources();
                }, 300);
                
            } catch (error) {
                console.debug('Console warm-up skipped:', error);
            }
        }
    }
    
    async preWarmWorkspaceServices() {
        // Pre-warm workspace API services to reduce first tab opening delay
        try {
            if (this.workspaceApi) {
                // Access workspace API methods to trigger service initialization
                // These calls don't actually open tabs but warm up the underlying services
                
                // 1. Check if we're in a console app (this initializes workspace detection)
                this.workspaceApi.isConsoleNavigation().then(() => {
                    console.log('Workspace API console detection warmed up');
                }).catch(error => {
                    console.debug('Workspace console detection warm-up skipped:', error);
                });
                
                // 2. Pre-initialize workspace tab handling (small delay to avoid blocking)
                setTimeout(() => {
                    // This gets the current workspace info which initializes workspace services
                    if (this.workspaceApi.getFocusedTabInfo) {
                        this.workspaceApi.getFocusedTabInfo().then(() => {
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
    
    preloadRecordPageResources() {
        // Preload critical resources for record page rendering
        try {
            // Create invisible elements to trigger resource loading
            const preloadElements = [];
            
            // Base record page resources
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
    
    connectedCallback() {
        // Clear any existing interval before setting new one
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
        }
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
        }
        
        // Console app warm-up optimizations
        this.warmUpConsoleApp();
        
        this.checkUserAssignments();
        this.refreshInterval = setInterval(() => {
            this.handleRefresh();
            this.checkUserAssignments();
        }, LeadQueueViewer.REFRESH_INTERVAL);
        
        // Start live timer updates
        this.timerInterval = setInterval(() => {
            this.currentTime = new Date();
            // Force re-render of table to update timers
            this.refreshTableTimers();
        }, 1000); // Update every second
    }

    renderedCallback() {
        // Intercept URL clicks for workspace navigation
        if (this.isConsoleNavigation) {
            const urlLinks = this.template.querySelectorAll('lightning-datatable a[href*="/lightning/r/litify_pm__Intake__c/"]');
            urlLinks.forEach(link => {
                if (!link.hasAttribute('data-workspace-handler')) {
                    link.setAttribute('data-workspace-handler', 'true');
                    link.addEventListener('click', (event) => {
                        event.preventDefault();
                        const href = link.getAttribute('href');
                        const recordId = href.match(/\/lightning\/r\/litify_pm__Intake__c\/([^\/]+)\//)?.[1];
                        if (recordId) {
                            this.navigateToRecord(recordId);
                        }
                    });
                }
            });
        }
    }
    
    disconnectedCallback() {
        // More robust cleanup to prevent memory leaks
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
            this.refreshInterval = null;
        }
        if (this.filterTimeout) {
            clearTimeout(this.filterTimeout);
            this.filterTimeout = null;
        }
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
            this.timerInterval = null;
        }
        
        // Enhanced cleanup to prevent memory leaks
        this.filterRequestId = 0;
        this.wiredQueueResult = null;
        this.originalRecords = [];
        this.records = [];
        this.activeTileFilter = null;
        this.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.filterOptions = { statusOptions: [], caseTypeOptions: [] };
        
        // Reset operational flags
        this.hasAssignments = false;
        this.isAssigning = false;
        this.isReleasing = false;
    }
    
    processQueueResponse(data) {
        // Validate data structure
        if (!data || typeof data !== 'object') {
            console.error('Invalid data structure received:', data);
            this.resetToEmptyState();
            return;
        }
        
        // Safe assignment with fallbacks - store original stats and keep them fixed
        this.originalStats = data.stats || { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        // queueStats should always show original values, never update with filters
        this.queueStats = { ...this.originalStats };
        this.filterOptions = data.filters || { statusOptions: [], caseTypeOptions: [] };
        
        // Validate records array
        if (!Array.isArray(data.records)) {
            console.error('Records is not an array:', data.records);
            this.records = [];
            return;
        }
        
        // Store original data for filter state management
        this.originalRecords = data.records
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
                    QualificationStatus: record.Qualification_Status__c || '',
                    callDateTime: this.formatCallDateTime(record.Call_at_Date__c),
                    Phone: record.litify_pm__Phone__c || '',
                    assignedTo: queueRecord.assignedTo || '',
                    assignmentTimer: this.getRecordAssignmentTimer(originalRecordId, queueRecord.assignedTo),
                    priorityRank: index + 1,
                    recordUrl: `/lightning/r/litify_pm__Intake__c/${originalRecordId}/view`,
                };
            });
        
        // Create working copy for display
        this.records = [...this.originalRecords];
        
        // Apply current tile filter if active
        this.applyClientSideFilter();
        
        // Warm up console navigation now that we have records
        this.warmUpWithRecords();
    }
    
    async warmUpWithRecords() {
        // Now that we have record data, warm up navigation systems
        if (this.isConsoleNavigation && this.originalRecords && this.originalRecords.length > 0) {
            try {
                // Get a sample record ID for warming up
                const sampleRecord = this.originalRecords.find(record => 
                    record.Id && !record.Id.endsWith('-assigned')
                );
                
                if (sampleRecord) {
                    console.log('Warming up console navigation with sample record...');
                    
                    // Pre-generate navigation URL to warm up the system
                    this[NavigationMixin.GenerateUrl]({
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
    
    resetToEmptyState() {
        this.records = [];
        this.originalRecords = [];
        this.originalStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.queueStats = { totalRecords: 0, highPriorityCount: 0, inContactCount: 0, noContactCount: 0, retainerSentCount: 0 };
        this.filterOptions = { statusOptions: [], caseTypeOptions: [] };
    }
    
    applyClientSideFilter() {
        if (this.activeTileFilter === 'highPriority') {
            this.records = this.originalRecords.filter(record => 
                record.Status === 'Intake Scheduled' || record.Status === 'Lead Generated'
            );
        } else if (this.activeTileFilter === 'inContact') {
            this.records = this.originalRecords.filter(record => 
                record.Status === 'In Contact/Under Review' || record.Status === 'Questionnaire' || record.Status === 'Missed Appointment'
            );
        } else if (this.activeTileFilter === 'noContact') {
            this.records = this.originalRecords.filter(record => 
                record.Status === 'Attempting to Contact'
            );
        } else if (this.activeTileFilter === 'retainerSent') {
            this.records = this.originalRecords.filter(record => 
                record.Status === 'Intake Package Sent'
            );
        } else {
            // No filter active, show all original records
            this.records = [...this.originalRecords];
        }
    }
    
    
    async handleRefresh() {
        try {
            await refreshApex(this.wiredQueueResult);
        } catch (error) {
            console.error('Refresh error details:', error);
            this.showToast('Error', 'Failed to refresh data: ' + this.getErrorMessage(error), 'error');
        }
    }
    
    async handleAssignNext() {
        this.isAssigning = true;
        try {
            const result = await assignNextAvailableRecord({ showScheduledCalls: this.showScheduledCalls });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(result.recordId);
                
                // Store assignment timestamp for timer
                this.storeAssignmentTimestamp(result.recordId);
                
                // Refresh data and assignments in parallel
                Promise.all([
                    refreshApex(this.wiredQueueResult),
                    this.checkUserAssignments()
                ]).then(() => {
                    // Force re-render of utility interface
                    this.dispatchEvent(new CustomEvent('assignmentchanged'));
                }).catch(error => {
                    console.error('Error refreshing after assignment:', error);
                });
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Assignment failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }
    
    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        
        // Extract original record ID by removing '-assigned' suffix
        const originalRecordId = row.Id.endsWith('-assigned') 
            ? row.Id.slice(0, -9) 
            : row.Id;
        
        switch (actionName) {
            case 'assign':
                this.assignRecordToUser(originalRecordId);
                break;
        }
    }
    
    
    async assignRecordToUser(recordId) {
        this.isAssigning = true;
        try {
            const result = await assignRecord({ recordId });
            
            if (result.success) {
                // Assignment success toast disabled per user request
                
                // Non-blocking navigation - don't wait for tab to open
                this.navigateToRecord(recordId);
                
                // Store assignment timestamp for timer
                this.storeAssignmentTimestamp(recordId);
                
                // Refresh data and assignments in parallel
                Promise.all([
                    refreshApex(this.wiredQueueResult),
                    this.checkUserAssignments()
                ]).then(() => {
                    // Force re-render of utility interface
                    this.dispatchEvent(new CustomEvent('assignmentchanged'));
                }).catch(error => {
                    console.error('Error refreshing after assignment:', error);
                });
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Assignment failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }
    
    async handleReleaseAssignments() {
        this.isReleasing = true;
        try {
            await releaseUserAssignments();
            this.showToast('Success', 'Released all assignments', 'success');
            this.hasAssignments = false;
            
            // Clear assignment timestamp
            this.clearAssignmentTimestamp();
            
            await Promise.all([
                refreshApex(this.wiredQueueResult),
                this.checkUserAssignments()
            ]);
            // Force re-render of utility interface
            this.dispatchEvent(new CustomEvent('assignmentchanged'));
        } catch (error) {
            this.showToast('Error', 'Release failed: ' + this.getErrorMessage(error), 'error');
        } finally {
            this.isReleasing = false;
        }
    }
    
    async checkUserAssignments() {
        try {
            const assignedIds = await getUserAssignedRecordIds();
            const oldHasAssignments = this.hasAssignments;
            this.hasAssignments = assignedIds.length > 0;
            
            // If assignment status changed, force a template refresh
            if (oldHasAssignments !== this.hasAssignments) {
                // Small delay to ensure DOM updates
                setTimeout(() => {
                    this.dispatchEvent(new CustomEvent('assignmentstatuschanged', {
                        detail: { hasAssignments: this.hasAssignments }
                    }));
                }, 100);
            }
        } catch (error) {
            console.error('Check assignments error details:', error);
            this.showToast('Error', 'Failed to check assignments: ' + this.getErrorMessage(error), 'error');
        }
    }
    
    handleFilterChange(event) {
        const filterName = event.target.name;
        const filterValue = event.detail.value;
        
        // Increment request ID to invalidate previous responses
        this.filterRequestId++;
        
        // Clear existing timeout and nullify reference
        if (this.filterTimeout) {
            clearTimeout(this.filterTimeout);
            this.filterTimeout = null;
        }
        
        // Set new timeout for debounced update
        this.filterTimeout = setTimeout(() => {
            if (filterName === 'status') {
                this.statusFilter = filterValue;
            } else if (filterName === 'caseType') {
                this.caseTypeFilter = filterValue;
            } else if (filterName === 'dueDate') {
                this.dueDateFilter = filterValue;
            }
            // Clear timeout reference after execution
            this.filterTimeout = null;
        }, 300);
    }
    
    async handleTileClick(event) {
        const filterType = event.currentTarget.dataset.filter;
        
        // Toggle logic: if same tile clicked, remove filter
        if (this.activeTileFilter === filterType) {
            this.activeTileFilter = null;
        } else {
            this.activeTileFilter = filterType;
        }
        
        try {
            await this.applyTileFilter();
            this.updateTileVisualState();
        } catch (error) {
            console.error('Tile filter error:', error);
            this.showToast('Error', 'Filter operation failed', 'error');
        }
    }
    
    async applyTileFilter() {
        // All tiles now use client-side filtering for consistency
        this.applyClientSideFilter();
    }
    
    
    updateTileVisualState() {
        // Update tile CSS classes for visual indication
        const tiles = this.template.querySelectorAll('.stat-card[data-filter]');
        tiles.forEach(tile => {
            const filterType = tile.dataset.filter;
            if (filterType === this.activeTileFilter) {
                tile.classList.add('active-filter');
            } else {
                tile.classList.remove('active-filter');
            }
        });
    }

    handleClearFilters() {
        // Increment request ID to invalidate any pending responses
        this.filterRequestId++;
        
        this.statusFilter = '';
        this.caseTypeFilter = '';
        this.dueDateFilter = '';
        this.activeTileFilter = null;
        
        // Restore original records and stats
        if (this.originalRecords.length > 0) {
            this.records = [...this.originalRecords];
        }
        
        this.updateTileVisualState();
    }
    
    handleTotalTileClick() {
        // Reset all filters to show all records
        this.handleClearFilters();
    }
    
    navigateToRecord(recordId) {
        if (this.isConsoleNavigation) {
            // In console navigation - open in workspace tab (non-blocking)
            this.openWorkspaceTab(recordId);
        } else {
            // Standard navigation for non-console apps
            this.fallbackNavigation(recordId);
        }
    }
    
    navigateToRecordNewTab(recordId) {
        // For console navigation, all records should open in workspace tabs
        this.navigateToRecord(recordId);
    }
    
    async openWorkspaceTab(recordId) {
        try {
            // Optimized workspace tab opening with better performance parameters
            const tabInfo = await openTab({
                recordId: recordId,
                focus: true,
                // Add URL for faster loading (avoids redirect resolution)
                url: `/lightning/r/litify_pm__Intake__c/${recordId}/view?layout=S_H_Record_Intake_Active_Intake`
            });
            console.log('Workspace tab opened:', tabInfo.tabId);
        } catch (error) {
            console.error('Failed to open workspace tab for record ' + recordId + ':', error);
            // Non-blocking fallback - don't interrupt user workflow
            this.fallbackNavigation(recordId);
        }
    }
    
    fallbackNavigation(recordId) {
        this[NavigationMixin.Navigate]({
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
    
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant
        }));
    }
    
    formatTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }

    formatCallDateTime(dateTimeValue) {
        if (!dateTimeValue) return '';
        
        try {
            const dateTime = new Date(dateTimeValue);
            return dateTime.toLocaleDateString('en-US', {
                month: '2-digit',
                day: '2-digit',
                year: 'numeric'
            }) + ' ' + dateTime.toLocaleTimeString('en-US', {
                hour: 'numeric',
                minute: '2-digit',
                hour12: true
            });
        } catch (error) {
            return '';
        }
    }
    
    getErrorMessage(error) {
        const userFriendlyMessages = {
            'FIELD_CUSTOM_VALIDATION_EXCEPTION': 'Invalid data provided',
            'INSUFFICIENT_ACCESS_OR_READONLY': 'Access denied',
            'QUERY_TIMEOUT': 'Request timed out, please try again',
            'REQUIRED_FIELD_MISSING': 'Required information is missing',
            'FIELD_INTEGRITY_EXCEPTION': 'Data validation error'
        };
        
        const errorCode = error?.body?.exceptionType || error?.name;
        return userFriendlyMessages[errorCode] || 'An error occurred. Please contact your administrator.';
    }
    
    get isLoading() {
        return this.wiredQueueResult?.loading || false;
    }
    
    get hasRecords() {
        return this.records.length > 0;
    }
    
    get isAssignButtonDisabled() {
        return this.isLoading || this.isAssigning || this.isReleasing;
    }
    
    get isReleaseButtonDisabled() {
        return this.isLoading || this.isReleasing || this.isAssigning;
    }
    
    get areRowActionsDisabled() {
        return this.isLoading || this.isAssigning || this.isReleasing;
    }
    
    get assignButtonLabel() {
        return this.isAssigning ? 'Assigning...' : 'Get Next Record';
    }
    
    get releaseButtonLabel() {
        return this.isReleasing ? 'Releasing...' : 'Release My Records';
    }

    get allLeadsClass() {
        return this.activeTileFilter === null ? 'stat-card active-filter' : 'stat-card';
    }

    get readyToCallVariant() {
        return this.showScheduledCalls ? 'neutral' : 'brand';
    }

    get scheduledCallsVariant() {
        return this.showScheduledCalls ? 'brand' : 'neutral';
    }

    // Utility bar mode computed properties
    get showUtilityInterface() {
        return this.utilityMode === true;
    }

    get showFullInterface() {
        return this.utilityMode !== true;
    }

    get assignedRecordInfo() {
        // For tooltip showing current assigned record name
        if (this.hasAssignments && this.records.length > 0) {
            const assignedRecord = this.records.find(record => record.assignedTo);
            return assignedRecord ? `Currently assigned: ${assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name}` : 'Record assigned';
        }
        return '';
    }

    get assignedRecordDisplayName() {
        // For utility bar display of assigned record name
        if (this.hasAssignments && this.records.length > 0) {
            const assignedRecord = this.records.find(record => record.assignedTo);
            return assignedRecord ? (assignedRecord.litify_pm__Display_Name__c || assignedRecord.Name) : 'Assigned Record';
        }
        return '';
    }

    get assignedRecordStatus() {
        // For utility bar display of record status
        if (this.hasAssignments && this.records.length > 0) {
            const assignedRecord = this.records.find(record => record.assignedTo);
            if (assignedRecord && assignedRecord.Status) {
                return `Status: ${assignedRecord.Status}`;
            }
        }
        return null;
    }

    get assignedRecordTimer() {
        // For utility bar display of assignment duration
        if (this.hasAssignments) {
            // Get assignment timestamp from cache using cache key
            const userId = this.currentUserId || '$User.Id';
            const cacheKey = `assignment_${userId}`;
            
            // Try to get timestamp from sessionStorage as fallback
            try {
                const assignmentData = sessionStorage.getItem(cacheKey);
                if (assignmentData) {
                    const parsedData = JSON.parse(assignmentData);
                    if (parsedData.assignedAt) {
                        const assignedTime = new Date(parsedData.assignedAt);
                        const diffMs = this.currentTime - assignedTime;
                        const totalSeconds = Math.floor(diffMs / 1000);
                        
                        const minutes = Math.floor(totalSeconds / 60);
                        const seconds = totalSeconds % 60;
                        
                        return `Time Assigned: ${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
                    }
                }
            } catch (error) {
                console.log('Could not parse assignment timestamp:', error);
            }
            
            // Fallback: show generic assigned status
            return 'Currently assigned';
        }
        return '';
    }

    storeAssignmentTimestamp(recordId) {
        try {
            const userId = this.currentUserId || '$User.Id';
            const cacheKey = `assignment_${userId}`;
            const assignmentData = {
                recordId: recordId,
                assignedAt: new Date().toISOString()
            };
            sessionStorage.setItem(cacheKey, JSON.stringify(assignmentData));
        } catch (error) {
            console.log('Could not store assignment timestamp:', error);
        }
    }

    clearAssignmentTimestamp() {
        try {
            const userId = this.currentUserId || '$User.Id';
            const cacheKey = `assignment_${userId}`;
            sessionStorage.removeItem(cacheKey);
        } catch (error) {
            console.log('Could not clear assignment timestamp:', error);
        }
    }

    getRecordAssignmentTimer(recordId, assignedTo) {
        // Only show timer if record is assigned and to current user
        if (!assignedTo) {
            return '';
        }
        
        // Check if this record is assigned to the current user
        const userId = this.currentUserId || '$User.Id';
        const cacheKey = `assignment_${userId}`;
        
        try {
            const assignmentData = sessionStorage.getItem(cacheKey);
            if (assignmentData) {
                const parsedData = JSON.parse(assignmentData);
                if (parsedData.recordId === recordId && parsedData.assignedAt) {
                    const assignedTime = new Date(parsedData.assignedAt);
                    const diffMs = this.currentTime - assignedTime;
                    const totalSeconds = Math.floor(diffMs / 1000);
                    
                    const minutes = Math.floor(totalSeconds / 60);
                    const seconds = totalSeconds % 60;
                    
                    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
                }
            }
        } catch (error) {
            console.log('Could not parse assignment timestamp for record:', error);
        }
        
        // For records assigned to other users, show assigned status
        return assignedTo ? 'Assigned' : '';
    }

    refreshTableTimers() {
        // Update timer values in the records array
        if (this.records && this.records.length > 0) {
            this.records = this.records.map(record => {
                const originalRecordId = record.Id.endsWith('-assigned') 
                    ? record.Id.slice(0, -9) 
                    : record.Id;
                return {
                    ...record,
                    assignmentTimer: this.getRecordAssignmentTimer(originalRecordId, record.assignedTo)
                };
            });
        }
    }

    showReadyToCalls() {
        if (this.showScheduledCalls) {
            this.showScheduledCalls = false;
            // Clear wire cache to force refresh
            if (this.wiredQueueResult) {
                refreshApex(this.wiredQueueResult);
            }
        }
    }

    showScheduledCallsView() {
        if (!this.showScheduledCalls) {
            this.showScheduledCalls = true;
            // Clear wire cache to force refresh
            if (this.wiredQueueResult) {
                refreshApex(this.wiredQueueResult);
            }
        }
    }
}