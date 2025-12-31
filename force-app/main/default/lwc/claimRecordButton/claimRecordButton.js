import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { subscribe as empSubscribe, unsubscribe as empUnsubscribe, onError } from 'lightning/empApi';
import { publish, subscribe as lmsSubscribe, unsubscribe as lmsUnsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import LEAD_QUEUE_REFRESH from '@salesforce/messageChannel/LeadQueueRefresh__c';
import {
    assignRecord,
    releaseUserAssignments,
    getUserAssignedRecordIds,
    isCacheConfigured
} from 'c/leadQueueApi';
import { SharedUtils } from 'c/sharedUtils';

export default class ClaimRecordButton extends NavigationMixin(LightningElement) {
    @api recordId;
    isAssigning = false;
    isReleasing = false;
    showSuccess = false;
    assignedRecordIds = [];
    isCacheReady = true;
    cdcChannel = '/data/litify_pm__Intake__ChangeEvent';
    cdcRelevantFields = new Set([
        'litify_pm__Status__c',
        'Priority_Score__c',
        'Queue_Case_Type__c',
        'Case_Type__c',
        'Type__c',
        'Call_at_Date__c',
        'Follow_Up_Date_Time__c',
        'Appointment_Date__c',
        'litify_pm__Sign_Up_Method__c',
        'Qualification_Status__c',
        'Test_Record__c',
        'litify_pm__Display_Name__c',
        'Referred_By_Name__c',
        'litify_pm__Phone__c',
        'Name'
    ]);
    empSubscription;
    eventRefreshTimeout;
    lmsSubscription;
    lmsOriginId;
    storageKey = 'leadQueueRefresh';
    storageListener;
    broadcastChannel;

    @wire(MessageContext) messageContext;

    // Check assignments on component load
    connectedCallback() {
        this.lmsOriginId = this.lmsOriginId || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
        this.storageListener = this.handleStorageEvent.bind(this);
        this.broadcastChannel = this.initializeBroadcastChannel();
        this.subscribeToRefreshEvents();
        this.subscribeToMessageChannel();
        this.registerStorageListener();
        this.checkCacheHealth();
        this.checkAssignments();
    }

    disconnectedCallback() {
        if (this.eventRefreshTimeout) {
            clearTimeout(this.eventRefreshTimeout);
            this.eventRefreshTimeout = null;
        }
        this.unsubscribeFromRefreshEvents();
        this.unsubscribeFromMessageChannel();
        this.unregisterStorageListener();
        this.closeBroadcastChannel();
    }

    renderedCallback() {
        if (!this.lmsSubscription && this.messageContext) {
            this.subscribeToMessageChannel();
        }
    }

    async subscribeToRefreshEvents() {
        if (this.empSubscription) {
            return;
        }
        try {
            this.empSubscription = await empSubscribe(this.cdcChannel, -1, (message) => {
                this.handleCdcMessage(message);
            });
        } catch (error) {
            console.error('Failed to subscribe to Lead Queue CDC events:', error);
        }

        onError((error) => {
            console.error('Lead Queue CDC error:', error);
        });
    }

    unsubscribeFromRefreshEvents() {
        if (!this.empSubscription) {
            return;
        }
        empUnsubscribe(this.empSubscription, () => {
            this.empSubscription = null;
        });
    }

    subscribeToMessageChannel() {
        if (this.lmsSubscription || !this.messageContext) {
            return;
        }
        this.lmsSubscription = lmsSubscribe(this.messageContext, LEAD_QUEUE_REFRESH, (payload) => {
            this.handleLmsMessage(payload);
        }, { scope: APPLICATION_SCOPE });
    }

    unsubscribeFromMessageChannel() {
        if (!this.lmsSubscription) {
            return;
        }
        lmsUnsubscribe(this.lmsSubscription);
        this.lmsSubscription = null;
    }

    scheduleEventRefresh() {
        if (this.eventRefreshTimeout) {
            return;
        }
        this.eventRefreshTimeout = setTimeout(async () => {
            this.eventRefreshTimeout = null;
            if (!this.isCacheReady) {
                await this.checkCacheHealth();
            }
            if (this.isCacheReady) {
                this.checkAssignments();
            } else {
                this.assignedRecordIds = [];
            }
        }, 500);
    }

    handleLmsMessage(payload) {
        if (!payload || payload.originId === this.lmsOriginId) {
            return;
        }
        this.scheduleEventRefresh();
    }

    publishLmsMessage(action) {
        if (!this.messageContext) {
            this.publishStorageMessage(action);
            return;
        }
        publish(this.messageContext, LEAD_QUEUE_REFRESH, {
            action,
            originId: this.lmsOriginId,
            source: 'claimRecordButton',
            timestamp: Date.now()
        });
        this.publishBroadcastMessage(action);
        this.publishStorageMessage(action);
    }

    registerStorageListener() {
        if (typeof window === 'undefined' || !window.addEventListener || !window.localStorage) {
            return;
        }
        window.addEventListener('storage', this.storageListener);
    }

    unregisterStorageListener() {
        if (typeof window === 'undefined' || !window.removeEventListener) {
            return;
        }
        window.removeEventListener('storage', this.storageListener);
    }

    publishStorageMessage(action) {
        if (typeof window === 'undefined' || !window.localStorage) {
            return;
        }
        try {
            const payload = {
                action,
                originId: this.lmsOriginId,
                source: 'claimRecordButton',
                timestamp: Date.now()
            };
            window.localStorage.setItem(this.storageKey, JSON.stringify(payload));
        } catch (error) {
            // Ignore storage errors to avoid blocking UI actions.
        }
    }

    handleStorageEvent(event) {
        if (!event || event.key !== this.storageKey || !event.newValue) {
            return;
        }
        try {
            const payload = JSON.parse(event.newValue);
            if (payload && payload.originId === this.lmsOriginId) {
                return;
            }
        } catch (error) {
            return;
        }
        this.scheduleEventRefresh();
    }

    initializeBroadcastChannel() {
        if (typeof BroadcastChannel !== 'function') {
            return null;
        }
        try {
            const channel = new BroadcastChannel(this.storageKey);
            channel.onmessage = (event) => {
                this.handleBroadcastMessage(event?.data);
            };
            return channel;
        } catch (error) {
            return null;
        }
    }

    closeBroadcastChannel() {
        if (!this.broadcastChannel) {
            return;
        }
        try {
            this.broadcastChannel.close();
        } catch (error) {
            // Ignore channel close errors.
        }
        this.broadcastChannel = null;
    }

    publishBroadcastMessage(action) {
        if (!this.broadcastChannel) {
            return;
        }
        try {
            this.broadcastChannel.postMessage({
                action,
                originId: this.lmsOriginId,
                source: 'claimRecordButton',
                timestamp: Date.now()
            });
        } catch (error) {
            // Ignore broadcast errors to avoid blocking UI actions.
        }
    }

    handleBroadcastMessage(payload) {
        if (!payload || payload.originId === this.lmsOriginId) {
            return;
        }
        this.scheduleEventRefresh();
    }

    handleCdcMessage(message) {
        const payload = message?.data?.payload;
        const header = payload?.ChangeEventHeader;
        if (!header) {
            return;
        }
        if (header.changeType && header.changeType != 'UPDATE') {
            this.scheduleEventRefresh();
            return;
        }
        const changedFields = header.changedFields;
        if (!Array.isArray(changedFields) || changedFields.length === 0) {
            this.scheduleEventRefresh();
            return;
        }
        const hasRelevantChange = changedFields.some((fieldName) => this.cdcRelevantFields.has(fieldName));
        if (hasRelevantChange) {
            this.scheduleEventRefresh();
        }
    }

    async checkCacheHealth() {
        try {
            const result = await isCacheConfigured();
            this.isCacheReady = result;
            return result;
        } catch (error) {
            console.error('Cache health check failed:', error);
            this.isCacheReady = false;
            return false;
        }
    }

    async checkAssignments() {
        try {
            const assignedIds = await getUserAssignedRecordIds();
            this.assignedRecordIds = assignedIds;
        } catch (error) {
            console.error('Error getting user assignments:', error);
            this.assignedRecordIds = [];
        }
    }

    get isCurrentRecordClaimed() {
        return this.assignedRecordIds.includes(this.recordId);
    }

    get hasOtherRecordClaimed() {
        return this.assignedRecordIds.length > 0 && !this.isCurrentRecordClaimed;
    }

    get canClaimThisRecord() {
        return this.assignedRecordIds.length === 0; // No assignments at all
    }

    get showCacheWarning() {
        return !this.isCacheReady;
    }

    get claimButtonLabel() {
        return this.isAssigning ? 'Claiming...' : 'Claim Record';
    }

    get releaseButtonLabel() {
        return this.isReleasing ? 'Releasing...' : 'Release this Record';
    }

    get isClaimButtonDisabled() {
        return this.isAssigning || this.isReleasing || !this.isCacheReady;
    }

    get isReleaseButtonDisabled() {
        return this.isAssigning || this.isReleasing || !this.isCacheReady;
    }

    async handleClaimRecord() {
        if (!this.recordId) {
            this.showToast('Error', 'No record ID available', 'error');
            return;
        }
        if (!await this.checkCacheHealth()) {
            this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
            return;
        }

        this.isAssigning = true;
        try {
            const result = await assignRecord({ recordId: this.recordId });
            
            if (result.success) {
                this.showSuccess = true;
                this.showToast('Success', 'Record claimed successfully', 'success');
                this.publishLmsMessage('assign');
                // Refresh assignments to update button state
                await this.refreshAssignments();
                // Clear success message after 3 seconds
                setTimeout(() => {
                    this.showSuccess = false;
                }, 3000);
            } else {
                this.showToast('Warning', result.message, 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to claim record: ' + SharedUtils.getErrorMessage(error), 'error');
        } finally {
            this.isAssigning = false;
        }
    }

    async handleReleaseRecord() {
        if (!await this.checkCacheHealth()) {
            this.showToast('Error', 'Platform Cache not configured. Please contact your administrator.', 'error');
            return;
        }
        this.isReleasing = true;
        try {
            await releaseUserAssignments({ recordId: this.recordId });
            this.showSuccess = true;
            this.showToast('Success', 'Record released successfully', 'success');
            this.publishLmsMessage('release');
            // Refresh assignments to update button state
            await this.refreshAssignments();
            // Clear success message after 3 seconds
            setTimeout(() => {
                this.showSuccess = false;
            }, 3000);
        } catch (error) {
            this.showToast('Error', 'Failed to release record: ' + SharedUtils.getErrorMessage(error), 'error');
        } finally {
            this.isReleasing = false;
        }
    }

    async refreshAssignments() {
        // Add small delay to ensure platform cache is updated
        setTimeout(async () => {
            try {
                const assignedIds = await getUserAssignedRecordIds();
                this.assignedRecordIds = assignedIds;
            } catch (error) {
                console.error('Error refreshing assignments:', error);
            }
        }, 500); // 500ms delay for cache sync
        
        // Also do immediate refresh attempt
        await this.checkAssignments();
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    openCacheSetup() {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: '/lightning/setup/PlatformCache/home'
            }
        });
    }
}
